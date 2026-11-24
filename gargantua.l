%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gargantua.tab.h"

int line = 1;
int comment_start = 1;
extern void yyerror(const char *s);

static char *lex_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (!p) { perror("malloc"); exit(1); }
    memcpy(p, s, n);
    return p;
}

static char *unescape_string(const char *raw) {
    size_t len = strlen(raw);
    char *out = (char *)malloc(len + 1);
    size_t i = 1, j = 0; /* skip outer quotes */
    while (i + 1 < len) {
        if (raw[i] == '\\' && i + 2 < len) {
            i++;
            switch (raw[i]) {
                case 'n':  out[j++] = '\n'; break;
                case 't':  out[j++] = '\t'; break;
                case 'r':  out[j++] = '\r'; break;
                case '\\': out[j++] = '\\'; break;
                case '"':  out[j++] = '"';  break;
                default:   out[j++] = raw[i]; break;
            }
        } else {
            out[j++] = raw[i];
        }
        i++;
    }
    out[j] = '\0';
    return out;
}

static char unescape_char(const char *raw) {
    if (raw[1] == '\\') {
        switch (raw[2]) {
            case 'n':  return '\n';
            case 't':  return '\t';
            case 'r':  return '\r';
            case '\\': return '\\';
            case '\'': return '\'';
            default:   return raw[2];
        }
    }
    return raw[1];
}
%}

DIGIT   [0-9]
LETTER  [a-zA-Z_]
ID      {LETTER}({LETTER}|{DIGIT})*

%x COMMENT

%%

[ \t\r]+                    { /* skip whitespace */ }
\n                          { line++; }

 /* ---------- comments ---------- */
"##"[^\r\n]*                { /* ignore single-line comment */ }
"#*"                        { comment_start = line; BEGIN(COMMENT); }
<COMMENT>[^*\n]+            { /* eat comment text */ }
<COMMENT>"*"+[^*#\n]*       { /* eat stars not followed by # */ }
<COMMENT>\n                 { line++; }
<COMMENT>"*"+"#"            { BEGIN(INITIAL); }
<COMMENT><<EOF>>            {
                                char buf[128];
                                snprintf(buf, sizeof(buf),
                                         "Lexical Error: unterminated comment starting at line %d",
                                         comment_start);
                                yyerror(buf);
                                BEGIN(INITIAL);
                                return 0;
                            }

 /* preprocessor */
"#use"                      { return KW_USE; }
"#def"                      { return KW_DEF; }
"<"[a-z]+">"                { yylval.str = lex_strdup(yytext); return TK_HEADER; }

 /*  declarations & data types */
"pod"                       { return KW_POD; }
"mass"                      { return TY_MASS_KW; }
"lux"                       { return TY_LUX_KW; }
"lumen"                     { return TY_LUMEN_KW; }
"sig"                       { return TY_SIG_KW; }
"msg"                       { return TY_MSG_KW; }
"flag"                      { return TY_FLAG_KW; }
"nil"                       { return TY_NIL_KW; }
"grid"                      { return KW_GRID; }
"vault"                     { return TY_VAULT_KW; }

"fix"                       { return KW_FIX; }
"keep"                      { return KW_KEEP; }
"galaxy"                    { return KW_GALAXY; }

"craft"                     { return KW_CRAFT; }
"hybrid"                    { return KW_HYBRID; }
"phase"                     { return KW_PHASE; }
"alias"                     { return KW_ALIAS; }

 /*functions*/
"Endurance"                 { return KW_ENDURANCE; }
"mission"                   { return KW_MISSION; }
"home"                      { return KW_HOME; }

 /*conditionals & jumps*/
"probe"                     { return KW_PROBE; }
"reprobe"                   { return KW_REPROBE; }
"planb"                     { return KW_PLANB; }
"wormhole"                  { return KW_WORMHOLE; }
"gate"                      { return KW_GATE; }
"singular"                  { return KW_SINGULAR; }
"eject"                     { return KW_EJECT; }
"skip"                      { return KW_SKIP; }

 /*loops*/
"orbit"                     { return KW_ORBIT; }
"drift"                     { return KW_DRIFT; }
"cycle"                     { return KW_CYCLE; }
"pulse"                     { return KW_PULSE; }
"sweep"                     { return KW_SWEEP; }
"from"                      { return KW_FROM; }
"to"                        { return KW_TO; }
"by"                        { return KW_BY; }
"in"                        { return KW_IN; }

 /*blocks & I/O*/
"launch"                    { return KW_LAUNCH; }
"land"                      { return KW_LAND; }
"recv"                      { return KW_RECV; }
"send"                      { return KW_SEND; }

 /*word operators*/
"fuse"                      { return OP_FUSE; }
"shed"                      { return OP_SHED; }
"thrust"                    { return OP_THRUST; }
"warp"                      { return OP_WARP; }
"resid"                     { return OP_RESID; }
"surge"                     { return OP_SURGE; }

"climb"                     { return OP_CLIMB; }
"fall"                      { return OP_FALL; }

"over"                      { return OP_OVER; }
"under"                     { return OP_UNDER; }
"over_eq"                   { return OP_OVER_EQ; }
"under_eq"                  { return OP_UNDER_EQ; }
"same"                      { return OP_SAME; }
"diff"                      { return OP_DIFF; }

"both"                      { return OP_BOTH; }
"either"                    { return OP_EITHER; }
"inv"                       { return OP_INV; }

"lock"                      { return OP_LOCK; }
"join"                      { return OP_JOIN; }
"twist"                     { return OP_TWIST; }
"mirror"                    { return OP_MIRROR; }
"pushl"                     { return OP_PUSHL; }
"pushr"                     { return OP_PUSHR; }

"as"                        { return KW_AS; }

 /*symbol operators*/
"<-"                        { return OP_ASSIGN; }
"<+>"                       { return OP_CONCAT; }
"~>"                        { return OP_QMARK; }
"~|"                        { return OP_COLON_TERN; }
"::"                        { return OP_SCOPE; }

 /*pointers, booleans, file I/O*/
"beam"                      { return KW_BEAM; }
"loc"                       { return KW_LOC; }
"peek"                      { return KW_PEEK; }
"dark"                      { return KW_DARK; }

"on"                        { yylval.ival = 1; return TK_BOOL; }
"off"                       { yylval.ival = 0; return TK_BOOL; }

"rd"                        { yylval.str = lex_strdup("r"); return TK_FILE_MODE; }
"wr"                        { yylval.str = lex_strdup("w"); return TK_FILE_MODE; }
"ad"                        { yylval.str = lex_strdup("a"); return TK_FILE_MODE; }

"vopen"|"vclose"|"vput"|"vget"|"vline"|"vend" {
                                yylval.str = lex_strdup(yytext);
                                return TK_FILE_FUNC;
                            }

 /*built-in library functions*/
"root"|"mag"|"hi"|"lo"|"len"|"rev"|"up"|"down"|"near"|"sn"|"cs"|"tn"|"ln"|"lg"|"hcf"|"lcm"|"copy"|"cat"|"cmp"|"find"|"sub"|"caps"|"lower"|"s2i"|"i2s"|"isnum"|"isltr"|"iscap"|"islow"|"isgap"|"tocap"|"tolow"|"rnd"|"sortx"|"swap"|"tick"|"leave"|"grab"|"drop" {
                                yylval.str = lex_strdup(yytext);
                                return TK_LIB_FUNC;
                            }

 /*literals*/
{DIGIT}+"."{DIGIT}+         { yylval.fval = atof(yytext); return TK_FLOAT; }
{DIGIT}+                    { yylval.ival = atoll(yytext); return TK_INT; }
\'([^'\\\n]|\\.)\'          { yylval.cval = unescape_char(yytext); return TK_CHAR; }
\"([^\"\\\n]|\\.)*\"        { yylval.str = unescape_string(yytext); return TK_STRING; }
\"([^\"\\\n]|\\.)*          {
                                yyerror("Lexical Error: unterminated string literal");
                                return 0;
                            }

 /*identifiers*/
{ID}                        { yylval.str = lex_strdup(yytext); return TK_ID; }

 /*terminator & punctuation*/
"!"                         { return '!'; }
[()\[\],:]                  { return yytext[0]; }

 /*unknown symbol */
.                           {
                                char buf[128];
                                snprintf(buf, sizeof(buf),
                                         "Lexical Error: unknown symbol '%s'", yytext);
                                yyerror(buf);
                            }

%%

int yywrap(void) {
    return 1;
}