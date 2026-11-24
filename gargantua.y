%{

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <time.h>

extern int yylex(void);
extern FILE *yyin;
extern int line;

FILE *out_fp = NULL;
int error_count = 0;

void yyerror(const char *s) {
    error_count++;
    if (out_fp)
        fprintf(out_fp, "[Error at line %d] %s\n", line, s);
    fprintf(stderr, "[Error at line %d] %s\n", line, s);
}

static char *xstrdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (!p) { perror("malloc"); exit(1); }
    memcpy(p, s, n);
    return p;
}

/*DATA TYPES & VALUES*/
typedef enum {
    DT_NIL = 0, DT_MASS, DT_LUX, DT_LUMEN, DT_SIG,
    DT_MSG, DT_FLAG, DT_VAULT, DT_PTR, DT_GRID, DT_CRAFT
} DataType;

typedef struct {
    DataType type;
    long long ival;
    double fval;
    char *sval;
    FILE *fp;
    int ptr_idx; /* symbol index for pointers (-1 = dark/NULL) */
} Val;

static Val make_nil(void)          { Val v; memset(&v, 0, sizeof(v)); v.type = DT_NIL;   v.ptr_idx = -1; return v; }
static Val make_mass(long long x)  { Val v = make_nil(); v.type = DT_MASS;  v.ival = x; return v; }
static Val make_lux(double x)      { Val v = make_nil(); v.type = DT_LUX;   v.fval = x; return v; }
static Val make_sig(char c)        { Val v = make_nil(); v.type = DT_SIG;   v.ival = (unsigned char)c; return v; }
static Val make_flag(int b)        { Val v = make_nil(); v.type = DT_FLAG;  v.ival = b ? 1 : 0; return v; }
static Val make_msg(const char *s) { Val v = make_nil(); v.type = DT_MSG;   v.sval = xstrdup(s); return v; }
static Val make_vault(FILE *f)     { Val v = make_nil(); v.type = DT_VAULT; v.fp = f; return v; }
static Val make_ptr(int idx)       { Val v = make_nil(); v.type = DT_PTR;   v.ptr_idx = idx; return v; }

static long long as_int(Val v) {
    if (v.type == DT_LUX || v.type == DT_LUMEN) return (long long)v.fval;
    if (v.type == DT_MSG) return v.sval ? atoll(v.sval) : 0;
    return v.ival;
}

static double as_double(Val v) {
    if (v.type == DT_LUX || v.type == DT_LUMEN) return v.fval;
    if (v.type == DT_MSG) return v.sval ? atof(v.sval) : 0.0;
    return (double)v.ival;
}

static int as_bool(Val v) {
    if (v.type == DT_LUX || v.type == DT_LUMEN) return v.fval != 0.0;
    if (v.type == DT_MSG) return v.sval && v.sval[0] != '\0';
    if (v.type == DT_PTR) return v.ptr_idx >= 0;
    return v.ival != 0;
}

static char *val_to_str(Val v) {
    char buf[128];
    switch (v.type) {
        case DT_MASS:  snprintf(buf, sizeof(buf), "%lld", v.ival); return xstrdup(buf);
        case DT_LUX:
        case DT_LUMEN: snprintf(buf, sizeof(buf), "%.6g", v.fval); return xstrdup(buf);
        case DT_SIG:   buf[0] = (char)v.ival; buf[1] = '\0'; return xstrdup(buf);
        case DT_FLAG:  return xstrdup(v.ival ? "on" : "off");
        case DT_MSG:   return xstrdup(v.sval ? v.sval : "");
        case DT_PTR:
            if (v.ptr_idx < 0) return xstrdup("dark");
            snprintf(buf, sizeof(buf), "beam@%d", v.ptr_idx);
            return xstrdup(buf);
        case DT_VAULT: return xstrdup(v.fp ? "<vault:open>" : "<vault:closed>");
        default:       return xstrdup("nil");
    }
}

static Val cast_val(Val v, DataType target) {
    switch (target) {
        case DT_MASS:  return make_mass(as_int(v));
        case DT_LUX:
        case DT_LUMEN: { Val r = make_lux(as_double(v)); r.type = target; return r; }
        case DT_SIG:   return make_sig((char)as_int(v));
        case DT_FLAG:  return make_flag(as_bool(v));
        case DT_MSG:   return make_msg(val_to_str(v));
        default:       return v;
    }
}

/* AST DEFINITIONS*/
typedef enum {
    NK_PROGRAM, NK_USE, NK_DEF, NK_ALIAS, NK_PHASE, NK_CRAFT_DEF,
    NK_FUNC_DEF, NK_MAIN_DEF, NK_BLOCK,
    NK_VAR_DECL, NK_ARR_DECL, NK_PTR_DECL, NK_CRAFT_DECL, NK_ALIAS_DECL,
    NK_ASSIGN, NK_ARR_ASSIGN, NK_FIELD_ASSIGN, NK_PEEK_ASSIGN,
    NK_INCDEC, NK_SEND, NK_RECV, NK_IF, NK_ELSEIF, NK_SWITCH, NK_CASE,
    NK_ORBIT, NK_DRIFT, NK_CYCLE, NK_PULSE, NK_SWEEP,
    NK_RETURN, NK_BREAK, NK_CONTINUE, NK_EXPR_STMT,
    NK_INT, NK_FLOAT, NK_CHAR, NK_STRING, NK_BOOL, NK_DARK, NK_FILE_MODE,
    NK_VAR, NK_ARR_GET, NK_FIELD_GET, NK_LOC, NK_PEEK,
    NK_BINOP, NK_UNOP, NK_TERNARY, NK_CAST,
    NK_CALL_FUNC, NK_CALL_LIB, NK_CALL_FILE, NK_PARAM, NK_FIELD_DEF
} NodeKind;

typedef struct ASTNode {
    NodeKind kind;
    int lineno;
    char *sval;       /* name, operator, literal string */
    char *sval2;      /* secondary name (e.g., struct type / field) */
    long long ival;   /* int/bool/char/qualifier */
    double fval;      /* float literal */
    DataType dtype;   /* declared or target type */
    struct ASTNode *a, *b, *c, *d;
    struct ASTNode *next;
} ASTNode;

static ASTNode *ast_new(NodeKind k) {
    ASTNode *n = (ASTNode *)calloc(1, sizeof(ASTNode));
    n->kind = k;
    n->lineno = line;
    return n;
}

static ASTNode *ast_append(ASTNode *head, ASTNode *item) {
    if (!head) return item;
    if (!item) return head;
    ASTNode *cur = head;
    while (cur->next) cur = cur->next;
    cur->next = item;
    return head;
}

ASTNode *program_root = NULL;

/*TABLES (SYMBOLS, FUNCTIONS, STRUCTS, ALIASES)*/
#define MAX_SYMS    1024
#define MAX_FIELDS  32
#define MAX_FUNCS   128
#define MAX_CRAFTS  64
#define MAX_ALIASES 64

typedef struct {
    char *name;
    Val val;
} FieldVal;

typedef struct {
    char *name;
    DataType type;
    DataType elem_type;
    int is_const;
    int scope;
    Val val;
    Val *arr;
    int arr_len;
    FieldVal fields[MAX_FIELDS];
    int field_count;
} Symbol;

typedef struct {
    char *name;
    DataType ret_type;
    ASTNode *params;
    ASTNode *body;
} FuncEntry;

typedef struct {
    char *name;
    ASTNode *fields;
} CraftEntry;

typedef struct {
    char *alias_name;
    DataType actual_type;
} AliasEntry;

static Symbol     symtab[MAX_SYMS];
static int        sym_count = 0;
static int        cur_scope = 0;
static int        frame_base = 0;

static FuncEntry  functab[MAX_FUNCS];
static int        func_count = 0;

static CraftEntry crafttab[MAX_CRAFTS];
static int        craft_count = 0;

static AliasEntry aliastab[MAX_ALIASES];
static int        alias_count = 0;

typedef enum { EX_NORMAL = 0, EX_BREAK, EX_CONTINUE, EX_RETURN } ExecStatus;
static ExecStatus exec_status = EX_NORMAL;
static Val        return_val;

static void runtime_error(int ln, const char *msg) {
    error_count++;
    if (out_fp) fprintf(out_fp, "[Runtime/Semantic Error at line %d] %s\n", ln, msg);
    fprintf(stderr, "[Runtime/Semantic Error at line %d] %s\n", ln, msg);
}

static int sym_find_idx(const char *name) {
    for (int i = sym_count - 1; i >= frame_base; i--) {
        if (strcmp(symtab[i].name, name) == 0) return i;
    }
    for (int i = frame_base - 1; i >= 0; i--) {
        if (symtab[i].scope == 0 && strcmp(symtab[i].name, name) == 0) return i;
    }
    return -1;
}

static int sym_add(const char *name, DataType type, int is_const, Val init_val) {
    if (sym_count >= MAX_SYMS) { runtime_error(0, "Symbol table overflow"); return -1; }
    int idx = sym_count++;
    memset(&symtab[idx], 0, sizeof(Symbol));
    symtab[idx].name = xstrdup(name);
    symtab[idx].type = type;
    symtab[idx].is_const = is_const;
    symtab[idx].scope = cur_scope;
    symtab[idx].val = init_val;
    return idx;
}

static void scope_pop(int target_scope) {
    while (sym_count > 0 && symtab[sym_count - 1].scope > target_scope) {
        sym_count--;
    }
    cur_scope = target_scope;
}

static DataType resolve_alias(const char *name) {
    for (int i = alias_count - 1; i >= 0; i--) {
        if (strcmp(aliastab[i].alias_name, name) == 0)
            return aliastab[i].actual_type;
    }
    return DT_NIL;
}

static CraftEntry *find_craft(const char *name) {
    for (int i = 0; i < craft_count; i++) {
        if (strcmp(crafttab[i].name, name) == 0) return &crafttab[i];
    }
    return NULL;
}

static FuncEntry *find_func(const char *name) {
    for (int i = 0; i < func_count; i++) {
        if (strcmp(functab[i].name, name) == 0) return &functab[i];
    }
    return NULL;
}

static Val default_val_for(DataType t) {
    switch (t) {
        case DT_MASS:  return make_mass(0);
        case DT_LUX:
        case DT_LUMEN: return make_lux(0.0);
        case DT_SIG:   return make_sig('\0');
        case DT_MSG:   return make_msg("");
        case DT_FLAG:  return make_flag(0);
        case DT_VAULT: return make_vault(NULL);
        case DT_PTR:   return make_ptr(-1);
        default:       return make_nil();
    }
}

/* Forward declarations for execution */
static Val  eval_expr(ASTNode *n);
static void exec_stmt(ASTNode *n);
static void exec_list(ASTNode *n);

%}

%union {
    long long ival;
    double fval;
    char cval;
    char *str;
    int dtype;
    struct ASTNode *node;
}

/*Tokens */
%token KW_USE KW_DEF
%token <str> TK_HEADER

%token KW_POD
%token TY_MASS_KW TY_LUX_KW TY_LUMEN_KW TY_SIG_KW TY_MSG_KW TY_FLAG_KW TY_NIL_KW TY_VAULT_KW
%token KW_GRID KW_FIX KW_KEEP KW_GALAXY
%token KW_CRAFT KW_HYBRID KW_PHASE KW_ALIAS

%token KW_ENDURANCE KW_MISSION KW_HOME
%token KW_PROBE KW_REPROBE KW_PLANB KW_WORMHOLE KW_GATE KW_SINGULAR KW_EJECT KW_SKIP
%token KW_ORBIT KW_DRIFT KW_CYCLE KW_PULSE KW_SWEEP KW_FROM KW_TO KW_BY KW_IN
%token KW_LAUNCH KW_LAND KW_RECV KW_SEND

%token OP_FUSE OP_SHED OP_THRUST OP_WARP OP_RESID OP_SURGE
%token OP_CLIMB OP_FALL
%token OP_OVER OP_UNDER OP_OVER_EQ OP_UNDER_EQ OP_SAME OP_DIFF
%token OP_BOTH OP_EITHER OP_INV
%token OP_LOCK OP_JOIN OP_TWIST OP_MIRROR OP_PUSHL OP_PUSHR
%token KW_AS OP_ASSIGN OP_CONCAT OP_QMARK OP_COLON_TERN OP_SCOPE

%token KW_BEAM KW_LOC KW_PEEK KW_DARK

%token <ival> TK_INT TK_BOOL
%token <fval> TK_FLOAT
%token <cval> TK_CHAR
%token <str>  TK_STRING TK_FILE_MODE TK_FILE_FUNC TK_LIB_FUNC TK_ID

/*Operator Precedence (Lowest to Highest)*/
%right OP_QMARK OP_COLON_TERN
%left  OP_EITHER
%left  OP_BOTH
%left  OP_JOIN
%left  OP_TWIST
%left  OP_LOCK
%left  OP_SAME OP_DIFF
%left  OP_OVER OP_UNDER OP_OVER_EQ OP_UNDER_EQ
%left  OP_PUSHL OP_PUSHR
%left  OP_FUSE OP_SHED OP_CONCAT
%left  OP_THRUST OP_WARP OP_RESID
%right OP_SURGE
%right UMINUS OP_INV OP_MIRROR KW_PEEK KW_LOC
%left  KW_AS

/* Non-Terminal Types */
%type <node> program program_list program_item
%type <node> preproc_stmt craft_def phase_def alias_def func_def main_def
%type <node> field_list field_decl enum_list param_list_opt param_list
%type <node> block stmt_list stmt var_decl
%type <node> if_stmt elseif_chain opt_else switch_stmt case_list opt_default
%type <node> expr const_lit arg_list_opt arg_list
%type <dtype> data_type
%type <ival> opt_qual

%start program

%%

program
    : program_list
      {
          program_root = ast_new(NK_PROGRAM);
          program_root->a = $1;
          $$ = program_root;
      }
    ;

program_list
    : /* empty */                 { $$ = NULL; }
    | program_list program_item   { $$ = ast_append($1, $2); }
    ;

program_item
    : preproc_stmt  { $$ = $1; }
    | craft_def     { $$ = $1; }
    | phase_def     { $$ = $1; }
    | alias_def     { $$ = $1; }
    | var_decl      { $$ = $1; }
    | func_def      { $$ = $1; }
    | main_def      { $$ = $1; }
    ;

/*Preprocessor*/
preproc_stmt
    : KW_USE TK_HEADER
      {
          $$ = ast_new(NK_USE);
          $$->sval = $2;
      }
    | KW_DEF TK_ID const_lit
      {
          $$ = ast_new(NK_DEF);
          $$->sval = $2;
          $$->a = $3;
      }
    ;

const_lit
    : TK_INT     { $$ = ast_new(NK_INT);    $$->ival = $1; }
    | TK_FLOAT   { $$ = ast_new(NK_FLOAT);  $$->fval = $1; }
    | TK_CHAR    { $$ = ast_new(NK_CHAR);   $$->ival = $1; }
    | TK_STRING  { $$ = ast_new(NK_STRING); $$->sval = $1; }
    | TK_BOOL    { $$ = ast_new(NK_BOOL);   $$->ival = $1; }
    ;

/*Composite Type Definitions*/
craft_def
    : KW_CRAFT TK_ID KW_LAUNCH field_list KW_LAND
      {
          $$ = ast_new(NK_CRAFT_DEF);
          $$->sval = $2;
          $$->a = $4;
      }
    | KW_HYBRID TK_ID KW_LAUNCH field_list KW_LAND
      {
          $$ = ast_new(NK_CRAFT_DEF);
          $$->sval = $2;
          $$->a = $4;
      }
    ;

field_list
    : field_decl              { $$ = $1; }
    | field_list field_decl   { $$ = ast_append($1, $2); }
    ;

field_decl
    : KW_POD data_type TK_ID '!'
      {
          $$ = ast_new(NK_FIELD_DEF);
          $$->dtype = (DataType)$2;
          $$->sval = $3;
      }
    ;

phase_def
    : KW_PHASE TK_ID KW_LAUNCH enum_list KW_LAND
      {
          $$ = ast_new(NK_PHASE);
          $$->sval = $2;
          $$->a = $4;
      }
    ;

enum_list
    : TK_ID
      {
          $$ = ast_new(NK_VAR);
          $$->sval = $1;
      }
    | enum_list ',' TK_ID
      {
          ASTNode *e = ast_new(NK_VAR);
          e->sval = $3;
          $$ = ast_append($1, e);
      }
    ;

alias_def
    : KW_ALIAS data_type TK_ID '!'
      {
          $$ = ast_new(NK_ALIAS);
          $$->dtype = (DataType)$2;
          $$->sval = $3;
      }
    ;

/*Functions & Main*/
func_def
    : KW_MISSION data_type TK_ID '(' param_list_opt ')' block
      {
          $$ = ast_new(NK_FUNC_DEF);
          $$->dtype = (DataType)$2;
          $$->sval = $3;
          $$->a = $5;
          $$->b = $7;
      }
    ;

main_def
    : KW_ENDURANCE '(' ')' block
      {
          $$ = ast_new(NK_MAIN_DEF);
          $$->a = $4;
      }
    ;

param_list_opt
    : /* empty */  { $$ = NULL; }
    | param_list   { $$ = $1; }
    ;

param_list
    : data_type TK_ID
      {
          $$ = ast_new(NK_PARAM);
          $$->dtype = (DataType)$1;
          $$->sval = $2;
      }
    | param_list ',' data_type TK_ID
      {
          ASTNode *p = ast_new(NK_PARAM);
          p->dtype = (DataType)$3;
          p->sval = $4;
          $$ = ast_append($1, p);
      }
    ;

/*  Data Types & Qualifiers  */
data_type
    : TY_MASS_KW   { $$ = DT_MASS;  }
    | TY_LUX_KW    { $$ = DT_LUX;   }
    | TY_LUMEN_KW  { $$ = DT_LUMEN; }
    | TY_SIG_KW    { $$ = DT_SIG;   }
    | TY_MSG_KW    { $$ = DT_MSG;   }
    | TY_FLAG_KW   { $$ = DT_FLAG;  }
    | TY_NIL_KW    { $$ = DT_NIL;   }
    | TY_VAULT_KW  { $$ = DT_VAULT; }
    ;

opt_qual
    : /* empty */        { $$ = 0; }
    | KW_FIX             { $$ = 1; }
    | KW_KEEP            { $$ = 2; }
    | KW_GALAXY          { $$ = 4; }
    | KW_GALAXY KW_FIX   { $$ = 5; }
    | KW_FIX KW_GALAXY   { $$ = 5; }
    ;

/*  Variable Declarations  */
var_decl
    : opt_qual KW_POD data_type TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_VAR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$3;
          $$->sval = $4;
          $$->a = $6;
      }
    | opt_qual KW_POD data_type TK_ID '!'
      {
          $$ = ast_new(NK_VAR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$3;
          $$->sval = $4;
      }
    | opt_qual KW_POD KW_GRID data_type TK_ID '[' expr ']' OP_ASSIGN '[' arg_list ']' '!'
      {
          $$ = ast_new(NK_ARR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$4;
          $$->sval = $5;
          $$->a = $7;
          $$->b = $11;
      }
    | opt_qual KW_POD KW_GRID data_type TK_ID '[' expr ']' '!'
      {
          $$ = ast_new(NK_ARR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$4;
          $$->sval = $5;
          $$->a = $7;
      }
    | opt_qual KW_POD KW_BEAM data_type TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_PTR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$4;
          $$->sval = $5;
          $$->a = $7;
      }
    | opt_qual KW_POD KW_BEAM data_type TK_ID '!'
      {
          $$ = ast_new(NK_PTR_DECL);
          $$->ival = $1;
          $$->dtype = (DataType)$4;
          $$->sval = $5;
      }
    | opt_qual KW_POD KW_CRAFT TK_ID TK_ID '!'
      {
          $$ = ast_new(NK_CRAFT_DECL);
          $$->ival = $1;
          $$->sval2 = $4;
          $$->sval = $5;
      }
    | opt_qual KW_POD KW_HYBRID TK_ID TK_ID '!'
      {
          $$ = ast_new(NK_CRAFT_DECL);
          $$->ival = $1;
          $$->sval2 = $4;
          $$->sval = $5;
      }
    | opt_qual KW_POD TK_ID TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_ALIAS_DECL);
          $$->ival = $1;
          $$->sval2 = $3;
          $$->sval = $4;
          $$->a = $6;
      }
    | opt_qual KW_POD TK_ID TK_ID '!'
      {
          $$ = ast_new(NK_ALIAS_DECL);
          $$->ival = $1;
          $$->sval2 = $3;
          $$->sval = $4;
      }
    ;

/*  Blocks & Statements  */
block
    : KW_LAUNCH stmt_list KW_LAND
      {
          $$ = ast_new(NK_BLOCK);
          $$->a = $2;
      }
    ;

stmt_list
    : /* empty */      { $$ = NULL; }
    | stmt_list stmt   { $$ = ast_append($1, $2); }
    ;

stmt
    : var_decl
      { $$ = $1; }
    | TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_ASSIGN);
          $$->sval = $1;
          $$->a = $3;
      }
    | TK_ID '[' expr ']' OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_ARR_ASSIGN);
          $$->sval = $1;
          $$->a = $3;
          $$->b = $6;
      }
    | TK_ID OP_SCOPE TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_FIELD_ASSIGN);
          $$->sval = $1;
          $$->sval2 = $3;
          $$->a = $5;
      }
    | KW_PEEK TK_ID OP_ASSIGN expr '!'
      {
          $$ = ast_new(NK_PEEK_ASSIGN);
          $$->sval = $2;
          $$->a = $4;
      }
    | TK_ID OP_CLIMB '!'
      { $$ = ast_new(NK_INCDEC); $$->sval = $1; $$->ival = 1; }
    | TK_ID OP_FALL '!'
      { $$ = ast_new(NK_INCDEC); $$->sval = $1; $$->ival = -1; }
    | OP_CLIMB TK_ID '!'
      { $$ = ast_new(NK_INCDEC); $$->sval = $2; $$->ival = 1; }
    | OP_FALL TK_ID '!'
      { $$ = ast_new(NK_INCDEC); $$->sval = $2; $$->ival = -1; }
    | TK_ID '(' arg_list_opt ')' '!'
      {
          ASTNode *call = ast_new(NK_CALL_FUNC);
          call->sval = $1;
          call->a = $3;
          $$ = ast_new(NK_EXPR_STMT);
          $$->a = call;
      }
    | TK_LIB_FUNC '(' arg_list_opt ')' '!'
      {
          ASTNode *call = ast_new(NK_CALL_LIB);
          call->sval = $1;
          call->a = $3;
          $$ = ast_new(NK_EXPR_STMT);
          $$->a = call;
      }
    | TK_FILE_FUNC '(' arg_list_opt ')' '!'
      {
          ASTNode *call = ast_new(NK_CALL_FILE);
          call->sval = $1;
          call->a = $3;
          $$ = ast_new(NK_EXPR_STMT);
          $$->a = call;
      }
    | KW_SEND '(' arg_list_opt ')' '!'
      {
          $$ = ast_new(NK_SEND);
          $$->a = $3;
      }
    | KW_RECV '(' TK_ID ')' '!'
      {
          $$ = ast_new(NK_RECV);
          $$->sval = $3;
      }
    | if_stmt
      { $$ = $1; }
    | switch_stmt
      { $$ = $1; }
    | KW_ORBIT TK_ID KW_FROM expr KW_TO expr KW_BY expr block
      {
          $$ = ast_new(NK_ORBIT);
          $$->sval = $2;
          $$->a = $4;
          $$->b = $6;
          $$->c = $8;
          $$->d = $9;
      }
    | KW_ORBIT TK_ID KW_FROM expr KW_TO expr block
      {
          $$ = ast_new(NK_ORBIT);
          $$->sval = $2;
          $$->a = $4;
          $$->b = $6;
          $$->c = NULL;
          $$->d = $7;
      }
    | KW_DRIFT '(' expr ')' block
      {
          $$ = ast_new(NK_DRIFT);
          $$->a = $3;
          $$->b = $5;
      }
    | KW_CYCLE block KW_DRIFT '(' expr ')' '!'
      {
          $$ = ast_new(NK_CYCLE);
          $$->a = $2;
          $$->b = $5;
      }
    | KW_PULSE '(' expr ')' block
      {
          $$ = ast_new(NK_PULSE);
          $$->a = $3;
          $$->b = $5;
      }
    | KW_SWEEP TK_ID KW_IN TK_ID block
      {
          $$ = ast_new(NK_SWEEP);
          $$->sval = $2;
          $$->sval2 = $4;
          $$->a = $5;
      }
    | KW_HOME expr '!'
      {
          $$ = ast_new(NK_RETURN);
          $$->a = $2;
      }
    | KW_HOME '!'
      {
          $$ = ast_new(NK_RETURN);
      }
    | KW_EJECT '!'
      { $$ = ast_new(NK_BREAK); }
    | KW_SKIP '!'
      { $$ = ast_new(NK_CONTINUE); }
    ;

/*  Conditionals & Switch  */
if_stmt
    : KW_PROBE '(' expr ')' block elseif_chain opt_else
      {
          $$ = ast_new(NK_IF);
          $$->a = $3;
          $$->b = $5;
          $$->c = $6;
          $$->d = $7;
      }
    ;

elseif_chain
    : /* empty */
      { $$ = NULL; }
    | elseif_chain KW_REPROBE '(' expr ')' block
      {
          ASTNode *e = ast_new(NK_ELSEIF);
          e->a = $4;
          e->b = $6;
          $$ = ast_append($1, e);
      }
    ;

opt_else
    : /* empty */      { $$ = NULL; }
    | KW_PLANB block   { $$ = $2; }
    ;

switch_stmt
    : KW_WORMHOLE '(' expr ')' KW_LAUNCH case_list opt_default KW_LAND
      {
          $$ = ast_new(NK_SWITCH);
          $$->a = $3;
          $$->b = $6;
          $$->c = $7;
      }
    ;

case_list
    : /* empty */
      { $$ = NULL; }
    | case_list KW_GATE expr ':' stmt_list
      {
          ASTNode *c = ast_new(NK_CASE);
          c->a = $3;
          c->b = $5;
          $$ = ast_append($1, c);
      }
    ;

opt_default
    : /* empty */
      { $$ = NULL; }
    | KW_SINGULAR ':' stmt_list
      {
          ASTNode *d = ast_new(NK_CASE);
          d->b = $3;
          $$ = d;
      }
    ;

/*  Expressions  */
arg_list_opt
    : /* empty */  { $$ = NULL; }
    | arg_list     { $$ = $1; }
    ;

arg_list
    : expr               { $$ = $1; }
    | arg_list ',' expr  { $$ = ast_append($1, $3); }
    ;

expr
    : TK_INT         { $$ = ast_new(NK_INT);       $$->ival = $1; }
    | TK_FLOAT       { $$ = ast_new(NK_FLOAT);     $$->fval = $1; }
    | TK_CHAR        { $$ = ast_new(NK_CHAR);      $$->ival = $1; }
    | TK_STRING      { $$ = ast_new(NK_STRING);    $$->sval = $1; }
    | TK_BOOL        { $$ = ast_new(NK_BOOL);      $$->ival = $1; }
    | KW_DARK        { $$ = ast_new(NK_DARK); }
    | TK_FILE_MODE   { $$ = ast_new(NK_FILE_MODE); $$->sval = $1; }
    | TK_ID          { $$ = ast_new(NK_VAR);       $$->sval = $1; }
    | TK_ID '[' expr ']'
      {
          $$ = ast_new(NK_ARR_GET);
          $$->sval = $1;
          $$->a = $3;
      }
    | TK_ID OP_SCOPE TK_ID
      {
          $$ = ast_new(NK_FIELD_GET);
          $$->sval = $1;
          $$->sval2 = $3;
      }
    | TK_ID '(' arg_list_opt ')'
      {
          $$ = ast_new(NK_CALL_FUNC);
          $$->sval = $1;
          $$->a = $3;
      }
    | TK_LIB_FUNC '(' arg_list_opt ')'
      {
          $$ = ast_new(NK_CALL_LIB);
          $$->sval = $1;
          $$->a = $3;
      }
    | TK_FILE_FUNC '(' arg_list_opt ')'
      {
          $$ = ast_new(NK_CALL_FILE);
          $$->sval = $1;
          $$->a = $3;
      }
    | '(' expr ')'            { $$ = $2; }
    | KW_LOC TK_ID            { $$ = ast_new(NK_LOC);  $$->sval = $2; }
    | KW_PEEK expr            { $$ = ast_new(NK_PEEK); $$->a = $2; }
    | expr KW_AS data_type    { $$ = ast_new(NK_CAST); $$->a = $1; $$->dtype = (DataType)$3; }
    | OP_SHED expr %prec UMINUS { $$ = ast_new(NK_UNOP); $$->sval = xstrdup("neg");    $$->a = $2; }
    | OP_INV expr               { $$ = ast_new(NK_UNOP); $$->sval = xstrdup("inv");    $$->a = $2; }
    | OP_MIRROR expr            { $$ = ast_new(NK_UNOP); $$->sval = xstrdup("mirror"); $$->a = $2; }
    | expr OP_FUSE expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("fuse");     $$->a = $1; $$->b = $3; }
    | expr OP_SHED expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("shed");     $$->a = $1; $$->b = $3; }
    | expr OP_THRUST expr     { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("thrust");   $$->a = $1; $$->b = $3; }
    | expr OP_WARP expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("warp");     $$->a = $1; $$->b = $3; }
    | expr OP_RESID expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("resid");    $$->a = $1; $$->b = $3; }
    | expr OP_SURGE expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("surge");    $$->a = $1; $$->b = $3; }
    | expr OP_CONCAT expr     { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("concat");   $$->a = $1; $$->b = $3; }
    | expr OP_OVER expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("over");     $$->a = $1; $$->b = $3; }
    | expr OP_UNDER expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("under");    $$->a = $1; $$->b = $3; }
    | expr OP_OVER_EQ expr    { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("over_eq");  $$->a = $1; $$->b = $3; }
    | expr OP_UNDER_EQ expr   { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("under_eq"); $$->a = $1; $$->b = $3; }
    | expr OP_SAME expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("same");     $$->a = $1; $$->b = $3; }
    | expr OP_DIFF expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("diff");     $$->a = $1; $$->b = $3; }
    | expr OP_BOTH expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("both");     $$->a = $1; $$->b = $3; }
    | expr OP_EITHER expr     { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("either");   $$->a = $1; $$->b = $3; }
    | expr OP_LOCK expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("lock");     $$->a = $1; $$->b = $3; }
    | expr OP_JOIN expr       { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("join");     $$->a = $1; $$->b = $3; }
    | expr OP_TWIST expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("twist");    $$->a = $1; $$->b = $3; }
    | expr OP_PUSHL expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("pushl");    $$->a = $1; $$->b = $3; }
    | expr OP_PUSHR expr      { $$ = ast_new(NK_BINOP); $$->sval = xstrdup("pushr");    $$->a = $1; $$->b = $3; }
    | expr OP_QMARK expr OP_COLON_TERN expr
      {
          $$ = ast_new(NK_TERNARY);
          $$->a = $1;
          $$->b = $3;
          $$->c = $5;
      }
    ;

%%

/*  AST INTERPRETER / EXECUTOR  */

static long long calc_hcf(long long a, long long b) {
    a = llabs(a); b = llabs(b);
    while (b != 0) { long long t = b; b = a % b; a = t; }
    return a;
}

static Val eval_lib_func(ASTNode *n) {
    const char *fn = n->sval;
    ASTNode *a1 = n->a;
    ASTNode *a2 = a1 ? a1->next : NULL;
    ASTNode *a3 = a2 ? a2->next : NULL;

    /* Special symbol-aware utilities */
    if (strcmp(fn, "len") == 0 && a1) {
        if (a1->kind == NK_VAR) {
            int idx = sym_find_idx(a1->sval);
            if (idx >= 0 && symtab[idx].type == DT_GRID)
                return make_mass(symtab[idx].arr_len);
        }
        Val v = eval_expr(a1);
        return make_mass(v.sval ? (long long)strlen(v.sval) : 0);
    }
    if (strcmp(fn, "sortx") == 0 && a1 && a1->kind == NK_VAR) {
        int idx = sym_find_idx(a1->sval);
        if (idx >= 0 && symtab[idx].type == DT_GRID) {
            for (int i = 0; i < symtab[idx].arr_len - 1; i++) {
                for (int j = 0; j < symtab[idx].arr_len - 1 - i; j++) {
                    if (as_double(symtab[idx].arr[j]) > as_double(symtab[idx].arr[j + 1])) {
                        Val tmp = symtab[idx].arr[j];
                        symtab[idx].arr[j] = symtab[idx].arr[j + 1];
                        symtab[idx].arr[j + 1] = tmp;
                    }
                }
            }
        }
        return make_nil();
    }
    if (strcmp(fn, "swap") == 0 && a1 && a2 && a1->kind == NK_VAR && a2->kind == NK_VAR) {
        int i1 = sym_find_idx(a1->sval), i2 = sym_find_idx(a2->sval);
        if (i1 >= 0 && i2 >= 0) {
            Val tmp = symtab[i1].val;
            symtab[i1].val = symtab[i2].val;
            symtab[i2].val = tmp;
        }
        return make_nil();
    }

    Val v1 = a1 ? eval_expr(a1) : make_nil();
    Val v2 = a2 ? eval_expr(a2) : make_nil();
    Val v3 = a3 ? eval_expr(a3) : make_nil();

    /* Math library */
    if (strcmp(fn, "root") == 0) return make_lux(sqrt(as_double(v1)));
    if (strcmp(fn, "mag") == 0)  return (v1.type == DT_MASS) ? make_mass(llabs(v1.ival)) : make_lux(fabs(as_double(v1)));
    if (strcmp(fn, "hi") == 0)   return (as_double(v1) >= as_double(v2)) ? v1 : v2;
    if (strcmp(fn, "lo") == 0)   return (as_double(v1) <= as_double(v2)) ? v1 : v2;
    if (strcmp(fn, "up") == 0)   return make_lux(ceil(as_double(v1)));
    if (strcmp(fn, "down") == 0) return make_lux(floor(as_double(v1)));
    if (strcmp(fn, "near") == 0) return make_mass((long long)llround(as_double(v1)));
    if (strcmp(fn, "sn") == 0)   return make_lux(sin(as_double(v1)));
    if (strcmp(fn, "cs") == 0)   return make_lux(cos(as_double(v1)));
    if (strcmp(fn, "tn") == 0)   return make_lux(tan(as_double(v1)));
    if (strcmp(fn, "ln") == 0)   return make_lux(log(as_double(v1)));
    if (strcmp(fn, "lg") == 0)   return make_lux(log10(as_double(v1)));
    if (strcmp(fn, "hcf") == 0)  return make_mass(calc_hcf(as_int(v1), as_int(v2)));
    if (strcmp(fn, "lcm") == 0) {
        long long x = llabs(as_int(v1)), y = llabs(as_int(v2));
        long long g = calc_hcf(x, y);
        return make_mass(g ? (x / g) * y : 0);
    }

    /* String & Char library */
    if (strcmp(fn, "rev") == 0) {
        char *s = val_to_str(v1);
        size_t len = strlen(s);
        for (size_t i = 0; i < len / 2; i++) {
            char t = s[i]; s[i] = s[len - 1 - i]; s[len - 1 - i] = t;
        }
        return make_msg(s);
    }
    if (strcmp(fn, "caps") == 0) {
        char *s = val_to_str(v1);
        for (size_t i = 0; s[i]; i++) s[i] = (char)toupper((unsigned char)s[i]);
        return make_msg(s);
    }
    if (strcmp(fn, "lower") == 0) {
        char *s = val_to_str(v1);
        for (size_t i = 0; s[i]; i++) s[i] = (char)tolower((unsigned char)s[i]);
        return make_msg(s);
    }
    if (strcmp(fn, "cat") == 0) {
        char *s1 = val_to_str(v1), *s2 = val_to_str(v2);
        char *res = (char *)malloc(strlen(s1) + strlen(s2) + 1);
        strcpy(res, s1); strcat(res, s2);
        return make_msg(res);
    }
    if (strcmp(fn, "copy") == 0) return make_msg(val_to_str(v1));
    if (strcmp(fn, "cmp") == 0)  return make_mass(strcmp(val_to_str(v1), val_to_str(v2)));
    if (strcmp(fn, "find") == 0) {
        char *s1 = val_to_str(v1), *s2 = val_to_str(v2);
        char *p = strstr(s1, s2);
        return make_mass(p ? (long long)(p - s1) : -1);
    }
    if (strcmp(fn, "sub") == 0) {
        char *s = val_to_str(v1);
        long long st = as_int(v2), ln = as_int(v3);
        long long total = (long long)strlen(s);
        if (st < 0 || st >= total || ln <= 0) return make_msg("");
        if (st + ln > total) ln = total - st;
        char *buf = (char *)malloc((size_t)ln + 1);
        memcpy(buf, s + st, (size_t)ln);
        buf[ln] = '\0';
        return make_msg(buf);
    }
    if (strcmp(fn, "s2i") == 0)   return make_mass(atoll(val_to_str(v1)));
    if (strcmp(fn, "i2s") == 0)   return make_msg(val_to_str(v1));
    if (strcmp(fn, "isnum") == 0) return make_flag(isdigit((unsigned char)as_int(v1)));
    if (strcmp(fn, "isltr") == 0) return make_flag(isalpha((unsigned char)as_int(v1)));
    if (strcmp(fn, "iscap") == 0) return make_flag(isupper((unsigned char)as_int(v1)));
    if (strcmp(fn, "islow") == 0) return make_flag(islower((unsigned char)as_int(v1)));
    if (strcmp(fn, "isgap") == 0) return make_flag(isspace((unsigned char)as_int(v1)));
    if (strcmp(fn, "tocap") == 0) return make_sig((char)toupper((unsigned char)as_int(v1)));
    if (strcmp(fn, "tolow") == 0) return make_sig((char)tolower((unsigned char)as_int(v1)));
    if (strcmp(fn, "rnd") == 0) {
        long long lim = a1 ? as_int(v1) : 100;
        return make_mass(lim > 0 ? (rand() % lim) : rand());
    }
    if (strcmp(fn, "tick") == 0)  return make_mass((long long)time(NULL));

    return make_nil();
}

static Val eval_file_func(ASTNode *n) {
    const char *fn = n->sval;
    ASTNode *a1 = n->a;
    ASTNode *a2 = a1 ? a1->next : NULL;

    if (strcmp(fn, "vopen") == 0 && a1 && a2) {
        Val fname = eval_expr(a1);
        Val mode  = eval_expr(a2);
        FILE *fp = fopen(val_to_str(fname), val_to_str(mode));
        if (!fp) runtime_error(n->lineno, "vopen failed to open file");
        return make_vault(fp);
    }
    if (strcmp(fn, "vclose") == 0 && a1) {
        if (a1->kind == NK_VAR) {
            int idx = sym_find_idx(a1->sval);
            if (idx >= 0 && symtab[idx].val.fp) {
                fclose(symtab[idx].val.fp);
                symtab[idx].val.fp = NULL;
            }
        }
        return make_nil();
    }
    if (strcmp(fn, "vput") == 0 && a1 && a2) {
        Val f = eval_expr(a1);
        Val d = eval_expr(a2);
        if (f.fp) fprintf(f.fp, "%s\n", val_to_str(d));
        return make_nil();
    }
    if ((strcmp(fn, "vline") == 0 || strcmp(fn, "vget") == 0) && a1) {
        Val f = eval_expr(a1);
        char buf[512] = "";
        if (f.fp && fgets(buf, sizeof(buf), f.fp)) {
            size_t len = strlen(buf);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
                buf[--len] = '\0';
        }
        return make_msg(buf);
    }
    if (strcmp(fn, "vend") == 0 && a1) {
        Val f = eval_expr(a1);
        return make_flag(!f.fp || feof(f.fp));
    }
    return make_nil();
}

static Val eval_user_func(ASTNode *n) {
    FuncEntry *f = find_func(n->sval);
    if (!f) {
        char buf[128];
        snprintf(buf, sizeof(buf), "Undefined mission '%s'", n->sval);
        runtime_error(n->lineno, buf);
        return make_nil();
    }

    /* Evaluate all arguments in caller's scope before switching frame */
    Val argvals[32];
    int argc = 0;
    for (ASTNode *arg = n->a; arg && argc < 32; arg = arg->next) {
        argvals[argc++] = eval_expr(arg);
    }

    int prev_scope = cur_scope;
    int prev_frame = frame_base;
    cur_scope++;
    frame_base = sym_count;

    int i = 0;
    for (ASTNode *p = f->params; p; p = p->next, i++) {
        Val v = (i < argc) ? cast_val(argvals[i], p->dtype) : default_val_for(p->dtype);
        sym_add(p->sval, p->dtype, 0, v);
    }

    ExecStatus saved_status = exec_status;
    exec_status = EX_NORMAL;
    return_val = default_val_for(f->ret_type);

    exec_stmt(f->body);

    Val result = (f->ret_type == DT_NIL) ? make_nil() : cast_val(return_val, f->ret_type);

    scope_pop(prev_scope);
    frame_base = prev_frame;
    exec_status = saved_status;
    return result;
}

static Val eval_expr(ASTNode *n) {
    if (!n) return make_nil();

    switch (n->kind) {
        case NK_INT:       return make_mass(n->ival);
        case NK_FLOAT:     return make_lux(n->fval);
        case NK_CHAR:      return make_sig((char)n->ival);
        case NK_STRING:    return make_msg(n->sval);
        case NK_BOOL:      return make_flag((int)n->ival);
        case NK_DARK:      return make_ptr(-1);
        case NK_FILE_MODE: return make_msg(n->sval);

        case NK_VAR: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0) {
                char buf[128];
                snprintf(buf, sizeof(buf), "Undeclared identifier '%s'", n->sval);
                runtime_error(n->lineno, buf);
                return make_nil();
            }
            return symtab[idx].val;
        }

        case NK_ARR_GET: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0 || symtab[idx].type != DT_GRID) {
                runtime_error(n->lineno, "Invalid grid access");
                return make_nil();
            }
            long long pos = as_int(eval_expr(n->a));
            if (pos < 0 || pos >= symtab[idx].arr_len) {
                runtime_error(n->lineno, "Grid index out of bounds");
                return make_nil();
            }
            return symtab[idx].arr[pos];
        }

        case NK_FIELD_GET: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0 || symtab[idx].type != DT_CRAFT) {
                runtime_error(n->lineno, "Invalid craft member access");
                return make_nil();
            }
            for (int i = 0; i < symtab[idx].field_count; i++) {
                if (strcmp(symtab[idx].fields[i].name, n->sval2) == 0)
                    return symtab[idx].fields[i].val;
            }
            runtime_error(n->lineno, "Unknown craft field");
            return make_nil();
        }

        case NK_LOC: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0) {
                runtime_error(n->lineno, "Cannot take 'loc' of undeclared variable");
                return make_ptr(-1);
            }
            return make_ptr(idx);
        }

        case NK_PEEK: {
            Val p = eval_expr(n->a);
            if (p.type != DT_PTR || p.ptr_idx < 0 || p.ptr_idx >= sym_count) {
                runtime_error(n->lineno, "Invalid or 'dark' pointer dereference");
                return make_nil();
            }
            return symtab[p.ptr_idx].val;
        }

        case NK_CAST:
            return cast_val(eval_expr(n->a), n->dtype);

        case NK_UNOP: {
            Val v = eval_expr(n->a);
            if (strcmp(n->sval, "neg") == 0)
                return (v.type == DT_LUX || v.type == DT_LUMEN) ? make_lux(-v.fval) : make_mass(-as_int(v));
            if (strcmp(n->sval, "inv") == 0)
                return make_flag(!as_bool(v));
            if (strcmp(n->sval, "mirror") == 0)
                return make_mass(~as_int(v));
            return v;
        }

        case NK_TERNARY: {
            Val cond = eval_expr(n->a);
            return as_bool(cond) ? eval_expr(n->b) : eval_expr(n->c);
        }

        case NK_BINOP: {
            const char *op = n->sval;
            /* Short-circuit logical operators */
            if (strcmp(op, "both") == 0)
                return make_flag(as_bool(eval_expr(n->a)) && as_bool(eval_expr(n->b)));
            if (strcmp(op, "either") == 0)
                return make_flag(as_bool(eval_expr(n->a)) || as_bool(eval_expr(n->b)));

            Val L = eval_expr(n->a);
            Val R = eval_expr(n->b);

            if (strcmp(op, "concat") == 0) {
                char *s1 = val_to_str(L), *s2 = val_to_str(R);
                char *res = (char *)malloc(strlen(s1) + strlen(s2) + 1);
                strcpy(res, s1); strcat(res, s2);
                return make_msg(res);
            }

            int is_fp = (L.type == DT_LUX || L.type == DT_LUMEN ||
                         R.type == DT_LUX || R.type == DT_LUMEN);

            if (strcmp(op, "fuse") == 0)
                return is_fp ? make_lux(as_double(L) + as_double(R)) : make_mass(as_int(L) + as_int(R));
            if (strcmp(op, "shed") == 0)
                return is_fp ? make_lux(as_double(L) - as_double(R)) : make_mass(as_int(L) - as_int(R));
            if (strcmp(op, "thrust") == 0)
                return is_fp ? make_lux(as_double(L) * as_double(R)) : make_mass(as_int(L) * as_int(R));
            if (strcmp(op, "warp") == 0) {
                if (as_double(R) == 0.0) { runtime_error(n->lineno, "Division by zero"); return make_mass(0); }
                return is_fp ? make_lux(as_double(L) / as_double(R)) : make_mass(as_int(L) / as_int(R));
            }
            if (strcmp(op, "resid") == 0) {
                if (as_int(R) == 0) { runtime_error(n->lineno, "Modulo by zero"); return make_mass(0); }
                return make_mass(as_int(L) % as_int(R));
            }
            if (strcmp(op, "surge") == 0) {
                double p = pow(as_double(L), as_double(R));
                return is_fp ? make_lux(p) : make_mass((long long)llround(p));
            }

            /* Relational */
            if (strcmp(op, "same") == 0) {
                if (L.type == DT_MSG && R.type == DT_MSG)
                    return make_flag(strcmp(L.sval, R.sval) == 0);
                return make_flag(as_double(L) == as_double(R));
            }
            if (strcmp(op, "diff") == 0) {
                if (L.type == DT_MSG && R.type == DT_MSG)
                    return make_flag(strcmp(L.sval, R.sval) != 0);
                return make_flag(as_double(L) != as_double(R));
            }
            if (strcmp(op, "over") == 0)     return make_flag(as_double(L) >  as_double(R));
            if (strcmp(op, "under") == 0)    return make_flag(as_double(L) <  as_double(R));
            if (strcmp(op, "over_eq") == 0)  return make_flag(as_double(L) >= as_double(R));
            if (strcmp(op, "under_eq") == 0) return make_flag(as_double(L) <= as_double(R));

            /* Bitwise */
            if (strcmp(op, "lock") == 0)  return make_mass(as_int(L) &  as_int(R));
            if (strcmp(op, "join") == 0)  return make_mass(as_int(L) |  as_int(R));
            if (strcmp(op, "twist") == 0) return make_mass(as_int(L) ^  as_int(R));
            if (strcmp(op, "pushl") == 0) return make_mass(as_int(L) << as_int(R));
            if (strcmp(op, "pushr") == 0) return make_mass(as_int(L) >> as_int(R));
            return make_nil();
        }

        case NK_CALL_FUNC: return eval_user_func(n);
        case NK_CALL_LIB:  return eval_lib_func(n);
        case NK_CALL_FILE: return eval_file_func(n);

        default: return make_nil();
    }
}

static void exec_list(ASTNode *n) {
    for (ASTNode *cur = n; cur && exec_status == EX_NORMAL; cur = cur->next) {
        exec_stmt(cur);
    }
}

static void exec_stmt(ASTNode *n) {
    if (!n || exec_status != EX_NORMAL) return;

    switch (n->kind) {
        case NK_BLOCK: {
            int prev = cur_scope;
            cur_scope++;
            exec_list(n->a);
            scope_pop(prev);
            break;
        }

        case NK_VAR_DECL: {
            Val v = n->a ? cast_val(eval_expr(n->a), n->dtype) : default_val_for(n->dtype);
            int is_const = (n->ival & 1) ? 1 : 0;
            sym_add(n->sval, n->dtype, is_const, v);
            break;
        }

        case NK_ALIAS_DECL: {
            DataType t = resolve_alias(n->sval2);
            if (t == DT_NIL) {
                runtime_error(n->lineno, "Unknown alias type");
                break;
            }
            Val v = n->a ? cast_val(eval_expr(n->a), t) : default_val_for(t);
            sym_add(n->sval, t, (n->ival & 1) ? 1 : 0, v);
            break;
        }

        case NK_ARR_DECL: {
            int sz = (int)as_int(eval_expr(n->a));
            if (sz <= 0) { runtime_error(n->lineno, "Grid size must be positive"); break; }
            int idx = sym_add(n->sval, DT_GRID, (n->ival & 1) ? 1 : 0, make_nil());
            if (idx < 0) break;
            symtab[idx].elem_type = n->dtype;
            symtab[idx].arr_len = sz;
            symtab[idx].arr = (Val *)calloc((size_t)sz, sizeof(Val));
            for (int i = 0; i < sz; i++) symtab[idx].arr[i] = default_val_for(n->dtype);
            int k = 0;
            for (ASTNode *el = n->b; el && k < sz; el = el->next, k++) {
                symtab[idx].arr[k] = cast_val(eval_expr(el), n->dtype);
            }
            break;
        }

        case NK_PTR_DECL: {
            Val v = n->a ? eval_expr(n->a) : make_ptr(-1);
            sym_add(n->sval, DT_PTR, (n->ival & 1) ? 1 : 0, v);
            break;
        }

        case NK_CRAFT_DECL: {
            CraftEntry *ce = find_craft(n->sval2);
            if (!ce) { runtime_error(n->lineno, "Undefined craft/hybrid type"); break; }
            int idx = sym_add(n->sval, DT_CRAFT, (n->ival & 1) ? 1 : 0, make_nil());
            if (idx < 0) break;
            int fc = 0;
            for (ASTNode *f = ce->fields; f && fc < MAX_FIELDS; f = f->next, fc++) {
                symtab[idx].fields[fc].name = xstrdup(f->sval);
                symtab[idx].fields[fc].val = default_val_for(f->dtype);
            }
            symtab[idx].field_count = fc;
            break;
        }

        case NK_ASSIGN: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0) { runtime_error(n->lineno, "Assignment to undeclared variable"); break; }
            if (symtab[idx].is_const) { runtime_error(n->lineno, "Cannot modify 'fix' constant"); break; }
            symtab[idx].val = cast_val(eval_expr(n->a), symtab[idx].type);
            break;
        }

        case NK_ARR_ASSIGN: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0 || symtab[idx].type != DT_GRID) {
                runtime_error(n->lineno, "Assignment to invalid grid"); break;
            }
            long long pos = as_int(eval_expr(n->a));
            if (pos < 0 || pos >= symtab[idx].arr_len) {
                runtime_error(n->lineno, "Grid index out of bounds"); break;
            }
            symtab[idx].arr[pos] = cast_val(eval_expr(n->b), symtab[idx].elem_type);
            break;
        }

        case NK_FIELD_ASSIGN: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0 || symtab[idx].type != DT_CRAFT) {
                runtime_error(n->lineno, "Field assignment on non-craft variable"); break;
            }
            int found = 0;
            for (int i = 0; i < symtab[idx].field_count; i++) {
                if (strcmp(symtab[idx].fields[i].name, n->sval2) == 0) {
                    symtab[idx].fields[i].val = cast_val(eval_expr(n->a), symtab[idx].fields[i].val.type);
                    found = 1;
                    break;
                }
            }
            if (!found) runtime_error(n->lineno, "Unknown craft field in assignment");
            break;
        }

        case NK_PEEK_ASSIGN: {
            int pidx = sym_find_idx(n->sval);
            if (pidx < 0 || symtab[pidx].val.type != DT_PTR || symtab[pidx].val.ptr_idx < 0) {
                runtime_error(n->lineno, "Invalid or 'dark' pointer in peek assignment"); break;
            }
            int target = symtab[pidx].val.ptr_idx;
            if (symtab[target].is_const) { runtime_error(n->lineno, "Cannot modify 'fix' constant via pointer"); break; }
            symtab[target].val = cast_val(eval_expr(n->a), symtab[target].type);
            break;
        }

        case NK_INCDEC: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0) { runtime_error(n->lineno, "climb/fall on undeclared variable"); break; }
            if (symtab[idx].is_const) { runtime_error(n->lineno, "Cannot climb/fall 'fix' constant"); break; }
            if (symtab[idx].type == DT_LUX || symtab[idx].type == DT_LUMEN)
                symtab[idx].val.fval += (double)n->ival;
            else
                symtab[idx].val.ival += n->ival;
            break;
        }

        case NK_EXPR_STMT:
            eval_expr(n->a);
            break;

        case NK_SEND: {
            int first = 1;
            for (ASTNode *arg = n->a; arg; arg = arg->next) {
                if (!first) fprintf(out_fp, " ");
                fprintf(out_fp, "%s", val_to_str(eval_expr(arg)));
                first = 0;
            }
            fprintf(out_fp, "\n");
            break;
        }

        case NK_RECV: {
            int idx = sym_find_idx(n->sval);
            if (idx < 0) { runtime_error(n->lineno, "recv into undeclared variable"); break; }
            char buf[256] = "";
            if (scanf("%255s", buf) == 1) {
                symtab[idx].val = cast_val(make_msg(buf), symtab[idx].type);
            }
            break;
        }

        case NK_IF: {
            if (as_bool(eval_expr(n->a))) {
                exec_stmt(n->b);
            } else {
                int taken = 0;
                for (ASTNode *ef = n->c; ef; ef = ef->next) {
                    if (as_bool(eval_expr(ef->a))) {
                        exec_stmt(ef->b);
                        taken = 1;
                        break;
                    }
                }
                if (!taken && n->d) exec_stmt(n->d);
            }
            break;
        }

        case NK_SWITCH: {
            Val sv = eval_expr(n->a);
            int matched = 0;
            for (ASTNode *c = n->b; c; c = c->next) {
                if (!matched) {
                    Val cv = eval_expr(c->a);
                    if ((sv.type == DT_MSG && cv.type == DT_MSG && strcmp(sv.sval, cv.sval) == 0) ||
                        (as_double(sv) == as_double(cv))) {
                        matched = 1;
                    }
                }
                if (matched) {
                    exec_list(c->b);
                    if (exec_status == EX_BREAK) { exec_status = EX_NORMAL; return; }
                    if (exec_status != EX_NORMAL) return;
                }
            }
            if (!matched && n->c) {
                exec_list(n->c->b);
                if (exec_status == EX_BREAK) exec_status = EX_NORMAL;
            }
            break;
        }

        case NK_ORBIT: {
            long long start = as_int(eval_expr(n->a));
            long long end   = as_int(eval_expr(n->b));
            long long step  = n->c ? as_int(eval_expr(n->c)) : 1;
            if (step == 0) { runtime_error(n->lineno, "orbit step cannot be 0"); break; }

            int prev = cur_scope;
            cur_scope++;
            int idx = sym_add(n->sval, DT_MASS, 0, make_mass(start));

            for (long long v = start; (step > 0) ? (v <= end) : (v >= end); v += step) {
                symtab[idx].val = make_mass(v);
                exec_stmt(n->d);
                if (exec_status == EX_BREAK)    { exec_status = EX_NORMAL; break; }
                if (exec_status == EX_CONTINUE) { exec_status = EX_NORMAL; continue; }
                if (exec_status == EX_RETURN)   break;
            }
            scope_pop(prev);
            break;
        }

        case NK_DRIFT: {
            while (as_bool(eval_expr(n->a))) {
                exec_stmt(n->b);
                if (exec_status == EX_BREAK)    { exec_status = EX_NORMAL; break; }
                if (exec_status == EX_CONTINUE) { exec_status = EX_NORMAL; continue; }
                if (exec_status == EX_RETURN)   break;
            }
            break;
        }

        case NK_CYCLE: {
            do {
                exec_stmt(n->a);
                if (exec_status == EX_BREAK)    { exec_status = EX_NORMAL; break; }
                if (exec_status == EX_CONTINUE) { exec_status = EX_NORMAL; }
                if (exec_status == EX_RETURN)   break;
            } while (as_bool(eval_expr(n->b)));
            break;
        }

        case NK_PULSE: {
            long long times = as_int(eval_expr(n->a));
            for (long long i = 0; i < times; i++) {
                exec_stmt(n->b);
                if (exec_status == EX_BREAK)    { exec_status = EX_NORMAL; break; }
                if (exec_status == EX_CONTINUE) { exec_status = EX_NORMAL; continue; }
                if (exec_status == EX_RETURN)   break;
            }
            break;
        }

        case NK_SWEEP: {
            int arr_idx = sym_find_idx(n->sval2);
            if (arr_idx < 0 || symtab[arr_idx].type != DT_GRID) {
                runtime_error(n->lineno, "sweep requires a valid grid"); break;
            }
            int prev = cur_scope;
            cur_scope++;
            int var_idx = sym_add(n->sval, symtab[arr_idx].elem_type, 0,
                                  default_val_for(symtab[arr_idx].elem_type));
            for (int i = 0; i < symtab[arr_idx].arr_len; i++) {
                symtab[var_idx].val = symtab[arr_idx].arr[i];
                exec_stmt(n->a);
                if (exec_status == EX_BREAK)    { exec_status = EX_NORMAL; break; }
                if (exec_status == EX_CONTINUE) { exec_status = EX_NORMAL; continue; }
                if (exec_status == EX_RETURN)   break;
            }
            scope_pop(prev);
            break;
        }

        case NK_RETURN:
            return_val = n->a ? eval_expr(n->a) : make_nil();
            exec_status = EX_RETURN;
            break;

        case NK_BREAK:
            exec_status = EX_BREAK;
            break;

        case NK_CONTINUE:
            exec_status = EX_CONTINUE;
            break;

        default:
            break;
    }
}

static void run_program(ASTNode *root) {
    if (!root) return;
    ASTNode *main_node = NULL;

    /* Pass 1: Register macros, aliases, enums, structs, globals, and functions */
    for (ASTNode *item = root->a; item; item = item->next) {
        switch (item->kind) {
            case NK_USE:
                /* Header library imported */
                break;
            case NK_DEF: {
                Val v = eval_expr(item->a);
                sym_add(item->sval, v.type, 1, v);
                break;
            }
            case NK_ALIAS:
                if (alias_count < MAX_ALIASES) {
                    aliastab[alias_count].alias_name = xstrdup(item->sval);
                    aliastab[alias_count].actual_type = item->dtype;
                    alias_count++;
                }
                break;
            case NK_PHASE: {
                long long val = 0;
                for (ASTNode *e = item->a; e; e = e->next, val++) {
                    sym_add(e->sval, DT_MASS, 1, make_mass(val));
                }
                break;
            }
            case NK_CRAFT_DEF:
                if (craft_count < MAX_CRAFTS) {
                    crafttab[craft_count].name = xstrdup(item->sval);
                    crafttab[craft_count].fields = item->a;
                    craft_count++;
                }
                break;
            case NK_FUNC_DEF:
                if (func_count < MAX_FUNCS) {
                    functab[func_count].name = xstrdup(item->sval);
                    functab[func_count].ret_type = item->dtype;
                    functab[func_count].params = item->a;
                    functab[func_count].body = item->b;
                    func_count++;
                }
                break;
            case NK_VAR_DECL:
            case NK_ARR_DECL:
            case NK_PTR_DECL:
            case NK_CRAFT_DECL:
            case NK_ALIAS_DECL:
                exec_stmt(item);
                break;
            case NK_MAIN_DEF:
                main_node = item;
                break;
            default:
                break;
        }
    }

    /* Pass 2: Execute Endurance() */
    if (!main_node) {
        runtime_error(0, "No Endurance() entry function found");
        return;
    }
    exec_stmt(main_node->a);
}

int main(void) {
    srand((unsigned int)time(NULL));

    yyin = fopen("input.txt", "r");
    if (!yyin) {
        printf("Error: cannot open input.txt\n");
        return 1;
    }
    out_fp = fopen("output.txt", "w");
    if (!out_fp) {
        printf("Error: cannot create output.txt\n");
        fclose(yyin);
        return 1;
    }

    fprintf(out_fp, " GARGANTUA COMPILER OUTPUT \n\n");

    if (yyparse() == 0 && error_count == 0) {
        run_program(program_root);
        fprintf(out_fp, "\n EXECUTION COMPLETED (%d ERRORS) n", error_count);
    } else {
        fprintf(out_fp, "\n COMPILATION FAILED (%d ERRORS) n", error_count);
    }

    fclose(yyin);
    fclose(out_fp);
    printf("Done. Check output.txt\n");
    return 0;
}