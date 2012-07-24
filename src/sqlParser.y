/*
 * SQLassie - database firewall
 * Copyright (C) 2011 Brandon Skari <brandon.skari@gmail.com>
 *
 * This file is part of SQLassie.
 *
 * SQLassie is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * SQLassie is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with SQLassie. If not, see <http://www.gnu.org/licenses/>.
 */

/**
 * Parser for MySQL queries. Derived from the parser for SQLite.
 * @author Brandon Skari
 * @date June 16 2012
 */

// The name of the generated procedure that implements the parser
// is as follows:
%name sqlassieParse

%token_type {TokenInfo*}
%extra_argument {ScannerContext* sc}

%type like_op       {LikeOpInfo}
%type in_op         {InOpInfo}
%type between_op    {BetweenOpInfo}

%type id    {TokenInfo*}
%type ids   {TokenInfo*}
%type nm    {TokenInfo*}

// The following text is included near the beginning of the C source
// code file that implements the parser.
//
%include {

#include <boost/cast.hpp>
#include <cassert>
#include <stack>

#include "AlwaysSomethingNode.hpp"
#include "AstNode.hpp"
#include "BooleanLogicNode.hpp"
#include "ExpressionNode.hpp"
#include "NegationNode.hpp"
#include "nullptr.hpp"
#include "OperatorNode.hpp"
#include "ScannerContext.hpp"
#include "TokenInfo.hpp"

struct LikeOpInfo
{
    int tokenType;
    bool negation;
};
struct BetweenOpInfo
{
    int tokenType;
    bool negation;
};
struct InOpInfo
{
    int inOpType;
    int comparisonType;  // Used for ANY and SOME
    bool negation;
};

// Give up parsing as soon as the first error is encountered
#define YYNOERRORRECOVERY 1

/**
 * Pushes a new ExpressionNode with two ExpressionNodes as leaves (taken from
 * the stack) and the given operator.
 */
static void addBooleanLogicNode(
    ScannerContext* const sc,
    const int operator_
)
{
    AstNode* const e = new BooleanLogicNode(operator_);

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    sc->nodes.push(e);
}


/**
 * Pushes a new ExpressionNode with two ExpressionNodes as leaves (taken from
 * the stack) and the given operator.
 */
static void addExpressionNode(
    ScannerContext* const sc,
    const int operator_
)
{
    AstNode* const e = new ExpressionNode;

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    e->addChild(new OperatorNode(operator_));

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    sc->nodes.push(e);
}


/**
 * Pushes a new ComparisonNode with two ExpressionNodes as leaves (taken from
 * the stack) and the given comparison type.
 */
static void addComparisonNode(
    ScannerContext* sc,
    const int comparisonType_,
    bool negation = false
)
{
    AstNode* const e = new ComparisonNode(comparisonType_);

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    e->addChild(sc->nodes.top());
    sc->nodes.pop();

    if (negation)
    {
        AstNode* const negationNode = new NegationNode;
        negationNode->addChild(e);
        sc->nodes.push(negationNode);
    }
    else
    {
        sc->nodes.push(e);
    }
}

} // end %include

%syntax_error {
    // Mark the query as invalid
    sc->qrPtr->valid = false;
}
// parse_failure is normally only called when Lemon's error recovery scheme
// fails miserably and the parser is hopelessly lost. syntax_failure is called
// for normal errors. Because I've defined YYNOERRORRECOVERY above, this
// should never be called, but just in case, I'll add it in.
%parse_failure {
    // Mark the query as invalid
    sc->qrPtr->valid = false;
    assert(
        false
        && "parse_failure should never be called if Lemon's error recovery is disabled. Check that error recovery is actually disabled."
    );
}

///////////////////// Begin parsing rules. ////////////////////////////
//

// Input is a single SQL command
input ::= cmd ecmd.
ecmd ::= .
ecmd ::= SEMI ecmd.

///////////////////// Begin and end transactions. ////////////////////////////
//

cmd ::= START TRANSACTION start_opt.
    {sc->qrPtr->queryType = QueryRisk::TYPE_TRANSACTION;}
cmd ::= BEGIN_KW work_opt.
    {sc->qrPtr->queryType = QueryRisk::TYPE_TRANSACTION;}
cmd ::= COMMIT work_opt chain_opt release_opt.
    {sc->qrPtr->queryType = QueryRisk::TYPE_TRANSACTION;}
cmd ::= ROLLBACK work_opt chain_opt release_opt.
    {sc->qrPtr->queryType = QueryRisk::TYPE_TRANSACTION;}
work_opt ::= .
work_opt ::= WORK.
start_opt ::= .
start_opt ::= WITH CONSISTENT SNAPSHOT.
chain_opt ::= .
chain_opt ::= AND no_opt CHAIN.
release_opt ::= .
release_opt ::= no_opt RELEASE.
no_opt ::= .
no_opt ::= NO.

// An IDENTIFIER can be a generic identifier, or one of several
// keywords.  Any non-standard keyword can also be an identifier.
//
id(A) ::= ID(X).            {A = X;}
id(A) ::= ID_FALLBACK(X).   {A = X;}

// The following directive causes tokens ABORT, AFTER, ASC, etc. to
// fallback to ID if they will not parse as their original value.
// This obviates the need for the "id" nonterminal.
%fallback ID_FALLBACK
  ASC BEGIN_KW BY CAST
  DATABASE DESC END EXPLAIN FOR
  IGNORE LIKE_KW MATCH_KW
  QUERY KEY OFFSET RELEASE REPLACE ROLLBACK
  // MySQL specific stuff
  LOW_PRIORITY DELAYED HIGH_PRIORITY CONSISTENT SNAPSHOT WORK CHAIN QUICK
  SOUNDS OUTFILE SQL_BIG_RESULT SQL_SMALL_RESULT SQL_BUFFER_RESULT SQL_CACHE
  SQL_NO_CACHE LOCK SHARE MODE BOOLEAN EXPANSION
  UNION
  FULL TABLES SCHEMA
  DEFAULT
  SOME ANY
  READ WRITE SESSION
  .

// I don't know what this does, so I'm going to remove it
//%wildcard ANY.

// Define operator precedence early so that this is the first occurance
// of the operator tokens in the grammer.  Keeping the operators together
// causes them to be assigned integer values that are close together,
// which keeps parser tables smaller.
//
// The token values assigned to these symbols is determined by the order
// in which lemon first sees them.  It must be the case that ISNULL/NOTNULL,
// NE/EQ, GT/LE, and GE/LT are separated by only a single value.  See
// the sqlite3ExprIfFalse() routine for additional information on this
// constraint.
//
%left OR.
%left XOR.
%left AND.
%right NOT SOME ANY.
%left IS MATCH_KW LIKE_KW SOUNDS BETWEEN IN NE EQ.
%left GT LE LT GE.
%right ESCAPE.
%left BITAND BITOR BITXOR LSHIFT RSHIFT.
%left PLUS MINUS.
%left STAR SLASH REM INTEGER_DIVIDE.
%left CONCAT.
%left COLLATE.
%right BITNOT.

// And "ids" is an identifer-or-string.
//
ids(A) ::= ID(X).       {A = X;}
ids(A) ::= STRING(X).   {A = X;}

// The name of a column or table can be any of the following:
//
nm(A) ::= id(X).         {A = X;}
nm(A) ::= STRING(X).     {A = X;}
nm(A) ::= JOIN_KW(X).    {A = X;}

// A typetoken is really one or more tokens that form a type name such
// as can be found after the column name in a CREATE TABLE statement.
// Multiple tokens are concatenated to form the value of the typetoken.
//
typetoken(A) ::= typename(X).   {A;X;}
typetoken(A) ::= typename(X) LP signed RP(Y). {A;X;Y;}
typetoken(A) ::= typename(X) LP signed COMMA signed RP(Y). {A;X;Y;}
typename(A) ::= ids(X).             {A;X;}
typename(A) ::= typename(X) ids(Y). {A;X;Y;}
plus_num(A) ::= number(X).          {A;X;}
minus_num(A) ::= MINUS number(X).   {A;X;}
number(A) ::= INTEGER|FLOAT.        {A;}
number(A) ::= HEX_NUMBER.           {A;}
signed ::= plus_num.
signed ::= minus_num.

//////////////////////// The SHOW statement /////////////////////////////////
//
cmd ::= SHOW DATABASES where_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
// MySQL doesn't allow NOT LIKE statements here, so don't use like_op
cmd ::= SHOW DATABASES LIKE_KW STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}

cmd ::= SHOW global_opt VARIABLES where_opt.
{
    /// @TODO(bskari|2012-07-08) Are any global variables risky?
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
cmd ::= SHOW global_opt VARIABLES LIKE_KW STRING.
{
    /// @TODO(bskari|2012-07-08) Are any global variables risky?
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
global_opt ::= GLOBAL.
global_opt ::= .

cmd ::= SHOW CREATE TABLE id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW CREATE SCHEMA id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW CREATE DATABASE id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}

// There are other commands too, like "SHOW FULL PROCESSLIST", "SHOW USERS", etc.
cmd ::= SHOW id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW id like_op expr.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW id id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW id id like_op expr.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}

// Using full_opt here wasn't working, so just copy/paste
cmd ::= SHOW TABLES show_from_in_id_opt where_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
cmd ::= SHOW FULL TABLES show_from_in_id_opt where_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
cmd ::= SHOW TABLES show_from_in_id_opt LIKE_KW STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW FULL TABLES show_from_in_id_opt LIKE_KW STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}

cmd ::= SHOW full_opt COLUMNS where_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
cmd ::= SHOW full_opt COLUMNS LIKE_KW STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}
cmd ::= SHOW full_opt COLUMNS from_in show_columns_id show_from_in_id_opt where_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
    // Pop the where_opt node
    sc->nodes.pop();
}
cmd ::= SHOW full_opt COLUMNS from_in show_columns_id show_from_in_id_opt LIKE_KW STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SHOW;
}

show_from_in_id_opt ::= .
show_from_in_id_opt ::= from_in id.

from_in ::= FROM.
from_in ::= IN.

show_columns_id ::= id.
show_columns_id ::= id DOT id.

full_opt ::= .
full_opt ::= FULL.

//////////////////////// The DESCRIBE statement ///////////////////////////////
//
// MySQL lets you use the DESC and EXPLAIN keyword for DESCRIBE
/// @TODO(bskari|2012-06-30) Support EXPLAIN keyword here.
describe_kw ::= DESC|DESCRIBE.
cmd ::= describe_kw id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_DESCRIBE;
}
cmd ::= describe_kw id id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_DESCRIBE;
}
// You can specify an individual column, or give a regex and show all columns
// that match it.
cmd ::= describe_kw id STRING.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_DESCRIBE;
}

//////////////////////// The EXPLAIN statement ///////////////////////////////
//
cmd ::= explain select_statement.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_EXPLAIN;
}
explain ::= EXPLAIN extended_opt.
extended_opt ::= .
extended_opt ::= EXTENDED.

//////////////////////// The USE statement ////////////////////////////////////
//
cmd ::= USE id.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_USE;
}

//////////////////////// The SET statement ////////////////////////////////////
//
cmd ::= SET set_assignments.    {sc->qrPtr->queryType = QueryRisk::TYPE_SET;}
// Set assignments are usually of the form "SET foo = 'bar'", but they can
// also look like "SET NAMES utf8"
set_assignments ::= set_assignment.
set_assignments ::= set_assignments COMMA set_assignment.
set_assignment ::= set_opt id EQ expr.
set_assignment ::= set_opt id expr.
set_assignment ::= GLOBAL_VARIABLE EQ expr.
{
    ++sc->qrPtr->globalVariables;
}
set_assignment ::= GLOBAL_VARIABLE DOT nm EQ expr.
{
    ++sc->qrPtr->globalVariables;
}
set_assignment ::= VARIABLE EQ expr.
set_assignment ::= VARIABLE DOT nm EQ expr.
// MySQL also has some long SET statements, like:
// SET GLOBAL TRANSACTION ISOLATION LEVEL REPEATABLE READ UNCOMMITTED
cmd ::= SET set_opt TRANSACTION bunch_of_ids.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_SET;
}
bunch_of_ids ::= .
bunch_of_ids ::= id bunch_of_ids.
set_opt ::= GLOBAL.
set_opt ::= SESSION.
set_opt ::= .

//////////////////////// The LOCK statement ///////////////////////////////////
//
cmd ::= LOCK TABLES lock_tables_list.   {sc->qrPtr->queryType = QueryRisk::TYPE_LOCK;}
lock_tables_list ::= as lock_type.
lock_tables_list ::= as lock_type COMMA lock_tables_list.
lock_type ::= READ local_opt.
lock_type ::= low_priority_opt WRITE.
local_opt ::= .
local_opt ::= LOCAL.
cmd ::= UNLOCK TABLES lock_tables_list. {sc->qrPtr->queryType = QueryRisk::TYPE_LOCK;}

//////////////////////// The SELECT statement /////////////////////////////////
//
cmd ::= select_statement.   {sc->qrPtr->queryType = QueryRisk::TYPE_SELECT;}
select_statement ::= select_opt select(X) outfile_opt lock_read_opt.   {X;}

select(A) ::= oneselect(X).                  {A;X;}
select(A) ::= select(X) multiselect_op(Y) oneselect(Z).  {A;X;Y;Z;}
multiselect_op(A) ::= UNION(OP).             {A;OP;}
multiselect_op(A) ::= UNION ALL.             {A;}
// EXCEPT and INTERSECT are not supported in MySQL
//multiselect_op(A) ::= EXCEPT|INTERSECT(OP).  {A;OP;}
oneselect ::= SELECT distinct selcollist from where_opt
                groupby_opt having_opt orderby_opt limit_opt.
{
    const ConditionalNode* const whereNode =
        boost::polymorphic_cast<const ConditionalNode*>(sc->nodes.top());
    sc->nodes.pop();
    sc->qrPtr->alwaysTrue = whereNode->isAlwaysTrue();
}

// The "distinct" nonterminal is true (1) if the DISTINCT keyword is
// present and false (0) if it is not.
//
distinct(A) ::= DISTINCT.       {A;}
distinct(A) ::= ALL.            {A;}
distinct(A) ::= DISTINCTROW.    {A;}
distinct(A) ::= .               {A;}

// MySQL specific select options
select_opt ::= high_priority_opt straight_join_opt
          sql_small_result_opt sql_big_result_opt sql_buffer_result_opt
          sql_cache_opt sql_calc_found_rows_opt .
high_priority_opt ::= .
high_priority_opt ::= HIGH_PRIORITY.
straight_join_opt ::= .
straight_join_opt ::= STRAIGHT_JOIN.
sql_small_result_opt ::= .
sql_small_result_opt ::= SQL_SMALL_RESULT.
sql_big_result_opt ::= .
sql_big_result_opt ::= SQL_BIG_RESULT.
sql_buffer_result_opt ::= .
sql_buffer_result_opt ::= SQL_BUFFER_RESULT.
sql_cache_opt ::= .
sql_cache_opt ::= SQL_CACHE.
sql_cache_opt ::= SQL_NO_CACHE.
sql_calc_found_rows_opt ::= .
sql_calc_found_rows_opt ::= SQL_CALC_FOUND_ROWS.

// MySQL specific outfile
outfile_opt ::= .
outfile_opt ::= INTO OUTFILE.

// MySQL specific read locking
lock_read_opt ::= .
lock_read_opt ::= FOR UPDATE.
lock_read_opt ::= LOCK IN SHARE MODE.

// selcollist is a list of expressions that are to become the return
// values of the SELECT statement.  The "*" in statements like
// "SELECT * FROM ..." is encoded as a special expression with an
// opcode of TK_ALL.
//
sclp(A) ::= selcollist(X) COMMA.             {A;X;}
sclp(A) ::= .                                {A;}
selcollist(A) ::= sclp(P) expr(X) as(Y).     {A;X;Y;P;}
selcollist(A) ::= sclp(P) STAR. {A;P;}
selcollist(A) ::= sclp(P) nm(X) DOT STAR(Y) as. {A;X;Y;P;}

// An option "AS <id>" phrase that can follow one of the expressions that
// define the result set, or one of the tables in the FROM clause.
//
as(X) ::= AS nm(Y).    {X;Y;}
as(X) ::= ids(Y).      {X;Y;}
as(X) ::= .            {X;}


// A complete FROM clause.
//
from(A) ::= .                {A;}
from(A) ::= FROM seltablist(X). {A;X;}

// MySQL match statement
//
mysql_match ::= MATCH_KW LP inscollist RP AGAINST LP expr againstmodifier_opt RP.
againstmodifier_opt ::= .
againstmodifier_opt ::= IN NATURAL LANGUAGE MODE.
againstmodifier_opt ::= IN BOOLEAN MODE.
againstmodifier_opt ::= WITH QUERY EXPANSION.

// "seltablist" is a "Select Table List" - the content of the FROM clause
// in a SELECT statement.  "stl_prefix" is a prefix of this list.
//
stl_prefix(A) ::= seltablist(X) joinop(Y).    {A;X;Y;}
stl_prefix(A) ::= .                           {A;}
seltablist ::= stl_prefix table_name dbnm as index_hint_list_opt on_opt using_opt.
seltablist(A) ::= stl_prefix(X) LP select(S) RP
                as(Z) index_hint_list_opt on_opt(N) using_opt(U). {A;X;S;Z;N;U;}
seltablist(A) ::= stl_prefix(X) LP seltablist(F) RP
                as(Z) index_hint_list_opt on_opt(N) using_opt(U). {A;X;F;Z;N;U;}

// A seltablist_paren nonterminal represents anything in a FROM that
// is contained inside parentheses.  This can be either a subquery or
// a grouping of table and subqueries.
//
//  %type seltablist_paren {Select*}
//  %destructor seltablist_paren {sqlite3SelectDelete(pParse->db, $$);}
//  seltablist_paren(A) ::= select(S).      {A = S;}
//  seltablist_paren(A) ::= seltablist(F).  {
//     sqlite3SrcListShiftJoinType(F);
//     A = sqlite3SelectNew(pParse,0,F,0,0,0,0,0,0,0);
//  }

table_name ::= id(X).
{
    sc->qrPtr->checkTable(X->scannedString_);
}
table_name ::= STRING(X).
{
    sc->qrPtr->checkTable(X->scannedString_);
}

dbnm ::= .
dbnm ::= DOT nm(X).
{
    sc->qrPtr->checkTable(X->scannedString_);
}

fullname ::= nm(X).
{
    sc->qrPtr->checkTable(X->scannedString_);
}
fullname ::= nm DOT nm(X).
{
    sc->qrPtr->checkTable(X->scannedString_);
}

joinop(X) ::= COMMA.                 {X;}
joinop(X) ::= join_opt JOIN_KW.         {X;}

join_opt ::= INNER.
join_opt ::= CROSS.
join_opt ::= natural_opt left_right_opt outer_opt.
left_right_opt ::= .
left_right_opt ::= LEFT.
left_right_opt ::= RIGHT.
natural_opt ::= .
natural_opt ::= NATURAL.
outer_opt ::= .
outer_opt ::= OUTER.

on_opt(N) ::= ON expr(E).   {N;E;}
on_opt(N) ::= .             {N;}

// MySQL specific indexing hints
index_hint_list_opt ::= .
index_hint_list_opt ::= index_hint_list.
index_hint_list ::= index_hint_list index_hint.
index_hint_list ::= index_hint.
index_hint ::= USE index_or_key_opt index_hint_for_opt LP index_list RP.
index_hint ::= IGNORE index_or_key_opt index_hint_for_opt LP index_list RP.
index_hint ::= FORCE index_or_key_opt index_hint_for_opt LP index_list RP.
index_or_key_opt ::= .
index_or_key_opt ::= INDEX.
index_or_key_opt ::= KEY.
index_hint_for_opt ::= .
index_hint_for_opt ::= FOR JOIN_KW.
index_hint_for_opt ::= FOR ORDER BY.
index_hint_for_opt ::= FOR GROUP BY.
index_list ::= nm .
index_list ::= nm COMMA index_list .

using_opt(U) ::= USING LP inscollist(L) RP.  {U;L;}
using_opt(U) ::= .                        {U;}

orderby_opt(A) ::= .                          {A;}
orderby_opt(A) ::= ORDER BY sortlist(X).      {A;X;}
sortlist(A) ::= sortlist(X) COMMA expr(Y) sortorder(Z). {A;X;Y;Z;}
sortlist(A) ::= expr(Y) sortorder(Z). {A;Y;Z;}

sortorder(A) ::= ASC.           {A;}
sortorder(A) ::= DESC.          {A;}
sortorder(A) ::= .              {A;}

groupby_opt(A) ::= .                      {A;}
groupby_opt(A) ::= GROUP BY nexprlist(X). {A;X;}

having_opt(A) ::= .                {A;}
having_opt(A) ::= HAVING expr(X).  {A;X;}

// The destructor for limit_opt will never fire in the current grammar.
// The limit_opt non-terminal only occurs at the end of a single production
// rule for SELECT statements.  As soon as the rule that create the
// limit_opt non-terminal reduces, the SELECT statement rule will also
// reduce.  So there is never a limit_opt non-terminal on the stack
// except as a transient.  So there is never anything to destroy.
//
//%destructor limit_opt {
//  sqlite3ExprDelete(pParse->db, $$.pLimit);
//  sqlite3ExprDelete(pParse->db, $$.pOffset);
//}
limit_opt(A) ::= .                    {A;}
limit_opt(A) ::= LIMIT expr(X).       {A;X;}
limit_opt(A) ::= LIMIT expr(X) OFFSET expr(Y). {A;X;Y;}
limit_opt(A) ::= LIMIT expr(X) COMMA expr(Y). {A;X;Y;}

/////////////////////////// The DELETE statement /////////////////////////////
//
cmd ::= DELETE delete_opt FROM fullname where_opt
        orderby_opt limit_opt.
{
    sc->qrPtr->queryType = QueryRisk::TYPE_DELETE;
    // Pop the where_opt node
    sc->nodes.pop();
}

delete_opt ::= low_priority_opt quick_opt ignore_opt.
low_priority_opt ::= .
low_priority_opt ::= LOW_PRIORITY.
quick_opt ::= .
quick_opt ::= QUICK.
ignore_opt ::= .
ignore_opt ::= IGNORE.
where_opt ::= .
{
    AstNode* const whereNode = new AlwaysSomethingNode(true, 0);
    sc->nodes.push(whereNode);
}
where_opt ::= WHERE expr.
{
    // Just leave the expr node on top of the nodes stack
}

////////////////////////// The UPDATE command ////////////////////////////////
//
cmd ::= UPDATE update_opt fullname(X) SET setlist(Y)
    where_opt(W) orderby_opt(O) limit_opt(L).
    {X;Y;W;O;L; sc->qrPtr->queryType = QueryRisk::TYPE_UPDATE;}

setlist(A) ::= setlist(Z) COMMA nm(X) EQ expr(Y). {A;X;Y;Z;}
setlist(A) ::= nm(X) EQ expr(Y). {A;X;Y;}

update_opt ::= .
update_opt ::= LOW_PRIORITY.
update_opt ::= IGNORE.

////////////////////////// The INSERT command /////////////////////////////////
//
/**
@TODO(bskari|2012-07-04)
 * Handle 'ON DUPLICATE KEY UPDATE col_name=expr [, col_name=expr] ...
 */
cmd ::= insert_cmd(R) insert_opt into_opt fullname(X) inscollist_opt(F) valuelist(Y).
    {R;X;Y;F; sc->qrPtr->queryType = QueryRisk::TYPE_INSERT;}
cmd ::= insert_cmd(R) insert_opt into_opt fullname(X) inscollist_opt(F) select(S).
    {R;X;F;S; sc->qrPtr->queryType = QueryRisk::TYPE_INSERT;}
cmd ::= insert_cmd(R) insert_opt into_opt fullname(X) inscollist_opt(F) DEFAULT VALUES.
    {R;X;F; sc->qrPtr->queryType = QueryRisk::TYPE_INSERT;}

into_opt ::= .
into_opt ::= INTO.

insert_opt ::= insert_priority_opt ignore_opt.
insert_priority_opt ::= .
insert_priority_opt ::= LOW_PRIORITY.
insert_priority_opt ::= DELAYED.
insert_priority_opt ::= HIGH_PRIORITY.

insert_cmd(A) ::= INSERT.   {A;}
insert_cmd(A) ::= REPLACE.  {A;}

// A ValueList is either a single VALUES clause or a comma-separated list
// of VALUES clauses.  If it is a single VALUES clause then the
// ValueList.pList field points to the expression list of that clause.
// If it is a list of VALUES clauses, then those clauses are transformed
// into a set of SELECT statements without FROM clauses and connected by
// UNION ALL and the ValueList.pSelect points to the right-most SELECT in
// that compound.
valuelist(A) ::= VALUES LP nexprlist(X) RP. {A;X;}

// Since a list of VALUEs is inplemented as a compound SELECT, we have
// to disable the value list option if compound SELECTs are disabled.
valuelist(A) ::= valuelist(X) COMMA LP exprlist(Y) RP. {A;X;Y;}

inscollist_opt(A) ::= .                      {A;}
inscollist_opt(A) ::= LP inscollist(X) RP.   {A;X;}
inscollist(A) ::= inscollist(X) COMMA nm(Y). {A;X;Y;}
inscollist(A) ::= nm(Y). {A;Y;}

/////////////////////////// Expression Processing /////////////////////////////
//

expr ::= term.
expr ::= LP expr RP.
expr ::= LP select RP.
{
    /// @TODO(bskari|2012-07-04) What should I do here?
    sc->nodes.push(new AlwaysSomethingNode(true));
}
term ::= NULL_KW.   {sc->nodes.push(new ExpressionNode("NULL", false));}
expr ::= id(X).
{
    ExpressionNode* e = new ExpressionNode(X->scannedString_, true);
    sc->nodes.push(e);
}
expr ::= JOIN_KW.
expr ::= nm(X) DOT id(Y).
{
    sc->qrPtr->checkTable(X->scannedString_);
    ExpressionNode* const e = new ExpressionNode(Y->scannedString_, true);
    sc->nodes.push(e);
}
expr ::= nm DOT table_name DOT id(X).
{
    ExpressionNode* const e = new ExpressionNode(X->scannedString_, true);
    sc->nodes.push(e);
}
term ::= INTEGER|FLOAT(X).
{
    ExpressionNode* const ex = new ExpressionNode(X->scannedString_, false);
    sc->nodes.push(ex);
}
term ::= HEX_NUMBER(X).
{
    /// @TODO Translate this to a decimal number?
    ExpressionNode* const ex = new ExpressionNode(X->scannedString_, false);
    sc->nodes.push(ex);
}
term ::= STRING(X).
{
    std::string& term = X->scannedString_;
    ExpressionNode* const ex = new ExpressionNode(term, false);
    sc->nodes.push(ex);
}
term ::= GLOBAL_VARIABLE(X).
{
    /// @TODO(bskari|2012-07-04) Check risky stuff?
    std::string& global = X->scannedString_;
    ExpressionNode* const ex = new ExpressionNode(global, false);
    sc->nodes.push(ex);
    ++sc->qrPtr->globalVariables;
}
term ::= GLOBAL_VARIABLE DOT id(X).
{
    /// @TODO(bskari|2012-07-04) Check risky stuff?
    std::string& identifier = X->scannedString_;
    ExpressionNode* const ex = new ExpressionNode(identifier, false);
    sc->nodes.push(ex);
    ++sc->qrPtr->globalVariables;
}
/* MySQL allows date intervals */
term ::= INTERVAL expr TIME_UNIT RP.
expr ::= VARIABLE.
expr ::= expr COLLATE ids.
expr ::= CAST LP expr AS typetoken RP.
expr ::= id(X) LP distinct exprlist RP.
{
    /// @TODO(bskari|2012-07-04) I should probably handle a bunch of possible
    /// functions here. For example, IF (1, 1, 0) should always be true.
    sc->nodes.push(new ExpressionNode(" ", false));
    sc->qrPtr->checkFunction(X->scannedString_);
}
expr ::= id(X) LP STAR RP.
{
    /// @TODO(bskari|2012-07-04) I should probably handle a bunch of possible
    /// functions here. For example, IF (1, 1, 0) should always be true.
    sc->nodes.push(new ExpressionNode(" ", false));
    sc->qrPtr->checkFunction(X->scannedString_);
}
expr ::= expr AND(OP) expr.
{
    addBooleanLogicNode(sc, OP->token_);
}
expr ::= expr OR(OP) expr.
{
    addBooleanLogicNode(sc, OP->token_);
}
expr ::= expr XOR(OP) expr.
{
    addBooleanLogicNode(sc, OP->token_);
}
expr ::= expr LT|GT|LE|GE(OP) expr.
{
    addComparisonNode(sc, OP->token_);
}
expr ::= expr EQ|NE(OP) expr.
{
    addComparisonNode(sc, OP->token_);
}
expr ::= expr BITAND|BITOR|BITXOR|LSHIFT|RSHIFT(OP) expr.
{
    addExpressionNode(sc, OP->token_);
}
expr ::= expr PLUS|MINUS(OP) expr.
{
    addExpressionNode(sc, OP->token_);
}
expr ::= expr STAR|SLASH|REM|INTEGER_DIVIDE(OP) expr.
{
    addExpressionNode(sc, OP->token_);
}
expr ::= expr CONCAT(OP) expr.
{
    addExpressionNode(sc, OP->token_);
}

like_op(A) ::= MATCH_KW(OP).        {A.negation = false; A.tokenType = OP->token_;}
like_op(A) ::= NOT MATCH_KW(OP).    {A.negation = true; A.tokenType = OP->token_;}
like_op(A) ::= LIKE_KW(OP).         {A.negation = false; A.tokenType = OP->token_;}
like_op(A) ::= NOT LIKE_KW(OP).     {A.negation = true; A.tokenType = OP->token_;}
like_op(A) ::= SOUNDS(OP) LIKE_KW.  {A.negation = false; A.tokenType = OP->token_;}

expr ::= expr like_op(B) expr. [LIKE_KW]
{
    addComparisonNode(sc, B.tokenType, B.negation);
}
expr ::= expr like_op(B) expr ESCAPE expr. [LIKE_KW]
{
    addComparisonNode(sc, B.tokenType, B.negation);
    /// @TODO(bskari|2012-07-04) Do I need to do anything with the last expr?
    delete sc->nodes.top();
    sc->nodes.pop();
}

expr ::= expr IS NULL_KW.
{
    const ExpressionNode* const ex = boost::polymorphic_downcast<ExpressionNode*>(
        sc->nodes.top()
    );
    // NULL IS NULL is always true, everything else is false, or safe enough
    // to always be considered false
    const bool alwaysTrue = (!ex->isIdentifier() && "NULL" != ex->getValue());
    AstNode* const asn = new AlwaysSomethingNode(alwaysTrue);
    asn->addChild(sc->nodes.top());
    sc->nodes.pop();
    asn->addChild(new ExpressionNode("NULL", false));
    sc->nodes.push(asn);
}
expr ::= expr IS NOT NULL_KW.
{
    const ExpressionNode* const ex = boost::polymorphic_downcast<ExpressionNode*>(
        sc->nodes.top()
    );
    // NULL IS NOT NULL is always false, everything else is true, or safe
    // enough to always be considered false
    const bool alwaysTrue = !(!ex->isIdentifier() && "NULL" != ex->getValue());
    AstNode* const asn = new AlwaysSomethingNode(alwaysTrue);
    asn->addChild(sc->nodes.top());
    sc->nodes.pop();
    asn->addChild(new ExpressionNode("NULL", false));
    sc->nodes.push(asn);
}
expr ::= NOT expr.
{
    const ConditionalNode* const cond =
        boost::polymorphic_downcast<ConditionalNode*>(sc->nodes.top());
    sc->nodes.pop();
    AstNode* const negationNode = new NegationNode;
    negationNode->addChild(cond);
    sc->nodes.push(negationNode);
}

/// @TODO(bskari|2012-07-04) Do something with these unary operators.
expr ::= BITNOT expr.
expr ::= MINUS(X) expr. [BITNOT]
{
    AstNode* negatedExpr = sc->nodes.top();
    sc->nodes.pop();
    AstNode* minus = new ExpressionNode;

    minus->addChild(new ExpressionNode("0", false));
    minus->addChild(new OperatorNode(X->token_));
    minus->addChild(negatedExpr);

    sc->nodes.push(minus);
}
expr ::= PLUS expr. [BITNOT]

between_op(A) ::= BETWEEN(X).
{
    A.negation = false;
    A.tokenType = X->token_;
}
between_op(A) ::= NOT BETWEEN(X).
{
    A.negation = true;
    A.tokenType = X->token_;
}
expr ::= expr between_op(N) expr AND expr. [BETWEEN]
{
    AstNode* const comparisonNode = new ComparisonNode(N.tokenType);

    AstNode* const maxExpr = sc->nodes.top();
    sc->nodes.pop();
    AstNode* const minExpr = sc->nodes.top();
    sc->nodes.pop();
    AstNode* const expr = sc->nodes.top();
    sc->nodes.pop();

    comparisonNode->addChild(expr);
    comparisonNode->addChild(minExpr);
    comparisonNode->addChild(maxExpr);
    if (N.negation)
    {
        AstNode* const negationNode = new NegationNode;
        negationNode->addChild(comparisonNode);
        sc->nodes.push(negationNode);
    }
    else
    {
        sc->nodes.push(comparisonNode);
    }
}
in_op(A) ::= IN(OP).        {A.negation = false; A.inOpType = OP->token_;}
in_op(A) ::= NOT IN(OP).    {A.negation = false; A.inOpType = OP->token_;}
expr(A) ::= expr(X) in_op(N) LP exprlist(Y) RP. [IN]    {A;X;Y;N;}
expr(A) ::= expr(X) in_op(N) LP select(Y) RP. [IN]      {A;X;Y;N;}
expr(A) ::= expr(X) in_op(N) nm(Y) dbnm(Z). [IN]        {A;X;Y;N;Z;}
//// MySQL ANY/SOME operators: = > < >= <= <> !=
//anyOrSome(A) ::= ANY|SOME.
//expr(A) ::= expr(X) EQ|NE(OP1) anyOrSome(OP2) LP select(Y) RP(E). [IN] {A;X;Y;N;E;}
//expr(A) ::= expr(X) LT|GT|LE|GT(OP1) anyOrSome(OP2) LP select(Y) RP(E). [IN] {A;X;Y;N;E;}

/* CASE expressions */
expr(A) ::= CASE(C) case_operand(X) case_exprlist(Y) case_else(Z) END(E). {A;X;Y;C;Z;E;}
case_exprlist(A) ::= case_exprlist(X) WHEN expr(Y) THEN expr(Z). {A;X;Y;Z;}
case_exprlist(A) ::= WHEN expr(Y) THEN expr(Z). {A;Y;Z;}
case_else(A) ::=  ELSE expr(X).         {A;X;}
case_else(A) ::=  .                     {A;}
case_operand(A) ::= expr(X).            {A;X;}
case_operand(A) ::= .                   {A;}

exprlist(A) ::= nexprlist(X).                {A;X;}
exprlist(A) ::= .                            {A;}
nexprlist(A) ::= nexprlist(X) COMMA expr(Y). {A;X;Y;}
nexprlist(A) ::= expr(Y). {A;Y;}

expr(A) ::= mysql_match.    {A;}