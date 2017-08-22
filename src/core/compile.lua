-- -*- Mode: Lua; -*-                                                                             
--
-- compile.lua (was c2)   RPL 1.1 compiler
--
-- © Copyright Jamie A. Jennings 2017.
-- LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)
-- AUTHOR: Jamie A. Jennings

-- FUTURE:
--   - Upon error in expression, throw out to compile_block, where the identifier (lhs of
--     binding) can be bound to the error.  Then we go on to try to compile other statements.
-- 

-- NOTE: The 'prefix' value is passed to all the compilation functions because it is needed when
-- labeling captures inside a grammar.


local c2 = {}

local lpeg = require "lpeg"
local locale = lpeg.locale()
local P, V, C, S, R, Cmt, B =
   lpeg.P, lpeg.V, lpeg.C, lpeg.S, lpeg.R, lpeg.Cmt, lpeg.B

local common = require "common"
local novalue = common.novalue
local taggedvalue = common.taggedvalue
local pattern = common.pattern
local pfunction = common.pfunction
local violation = require "violation"
local apply_catch = violation.catch
local recordtype = require "recordtype"
parent = recordtype.parent
local environment = require "environment"
lookup = environment.lookup
bind = environment.bind
local expand = require "expand"

local function throw(msg, a)
   return violation.throw(violation.compile.new{who='compiler',
						message=msg,
						ast=a})
end
						
---------------------------------------------------------------------------------------------------
-- Create parser
---------------------------------------------------------------------------------------------------

local function make_parser_from(parse_something, expected_pt_node)
   return function(source_record, messages)
	     assert(common.source.is(source_record))
	     assert(type(messages)=="table", "missing messages arg?")
	     local src = source_record.text
	     local origin = source_record.origin
	     assert(type(src)=="string", "src is " .. tostring(src))
	     assert(origin==nil or common.loadrequest.is(origin), "origin is: " .. tostring(origin))
	     local pt, syntax_errors, leftover = parse_something(src)
	     if #syntax_errors > 0 then
		-- TODO: Use the parse tree, pt, to help pinpoint the error
		-- OR, go directly to using the 'trace' capability for this, since that's the
		-- future solution anyway.
		for _, err in ipairs(syntax_errors) do
		   if common.type_is_syntax_error(err.type) then
		      -- In this case, the pt root is the syntax error.
		      assert(false, "** TODO: DECIDE WHAT TO DO IN THIS CASE **")
		   else
		      for _, sub in ipairs(err.subs or {}) do
			 if common.type_is_syntax_error(sub.type) then
			    local origin = origin and common.loadrequest.new{filename=origin.filename}
			    local sref = common.source.new{text=pt.data,
							   s=sub.s,
							   e=sub.e,
							   origin=origin,
							   parent=source_record}
			    local message = "syntax error"
			    if sub.subs and sub.subs[1] then
			       if sub.subs[1].type=="stmnt_prefix" then
				  message = "Expected expression but found assignment"
				  -- ... to identifier sub.subs[1].subs[1]--> localname/packagename
			       end
			    end
			    local v = violation.syntax.new{who='parser',
							   message=message,
							   sourceref=sref}
			    table.insert(messages, v)
			 end
		      end -- for each sub
		   end -- for either the root or one of its subs are syntax errors
		end -- for each syntax error node found 
		return false
	     end -- if syntax errors were returned

	     -- TODO: convert each "warning" here into a violation.warning
	     -- table.move(syntax_errors, 1, #syntax_errors, #messages+1, messages)

	     assert(type(pt)=="table")

	     if expected_pt_node then
		assert(pt.type==expected_pt_node,
		       string.format("pt.type is %s but expected %q",
				     tostring(pt.type), tostring(expected_pt_node)))
		--util.table_to_pretty_string(pt, false)
	     end
	     if leftover~=0 then
		local msg = "extraneous input: " .. src:sub(#src-leftover+1)
		local err = violation.syntax.new{who='parser', message=msg, sourceref=source_record}
		table.insert(messages, err)
		return false
	     end
	     return ast.from_parse_tree(pt, source_record)
	  end
end

function c2.make_parse_block(rplx_preparse, rplx_statements, supported_version)
   local parse_block = parse.make_parse_block(rplx_preparse, rplx_statements, supported_version)
   return make_parser_from(parse_block, "rpl_statements")
end

function c2.make_parse_expression(rplx_expression)
   local parse_expression = parse.make_parse_expression(rplx_expression)
   return make_parser_from(parse_expression, "rpl_expression")
end

c2.dependencies_of = ast.dependencies_of

---------------------------------------------------------------------------------------------------
-- Syntax expander
---------------------------------------------------------------------------------------------------

c2.expand_block = expand.block
c2.expand_expression = expand.expression

---------------------------------------------------------------------------------------------------
-- Compile expressions
---------------------------------------------------------------------------------------------------

local expression;

local function literal(a, env, prefix, messages)
   local str, offense = common.unescape_string(a.value)
   if not str then
      throw("invalid escape sequence in literal: \\" .. offense, a)
   end
   a.pat = pattern.new{name="literal"; peg=P(str); ast=a}
   return a.pat
end

local function rpl_string(a, env, prefix, messages)
   local str, offense = common.unescape_string(a.value)
   if not str then
      throw("invalid escape sequence in string: \\" .. offense, a)
   end
   a.pat = taggedvalue.new{type="string"; value=str; ast=a}
   return a.pat
end

local function hashtag(a, env, prefix, messages)
   local str = a.value
   assert(type(str)=="string")
   a.pat = taggedvalue.new{type="hashtag"; value=str; ast=a}
   return a.pat
end

local function sequence(a, env, prefix, messages)
   assert(#a.exps > 0, "empty sequence?")
   local peg = expression(a.exps[1], env, prefix, messages).peg
   for i = 2, #a.exps do
      peg = peg * expression(a.exps[i], env, prefix, messages).peg
   end
   a.pat = pattern.new{name="sequence", peg=peg, ast=a}
   return a.pat
end

local function choice(a, env, prefix, messages)
   assert(#a.exps > 0, "empty choice?")
   local peg = expression(a.exps[1], env, prefix, messages).peg
   for i = 2, #a.exps do
      peg = peg + expression(a.exps[i], env, prefix, messages).peg
   end
   a.pat = pattern.new{name="choice", peg=peg, ast=a}
   return a.pat
end

local function predicate(a, env, prefix, messages)
   local peg = expression(a.exp, env, prefix, messages).peg
   if a.type=="lookahead" then
      peg = #peg
   elseif a.type=="lookbehind" then
      local ok
      ok, peg = pcall(lpeg.B, peg)
      if not ok then
	 assert(type(peg)=="string")
	 if peg:find("fixed length") then
	    throw("lookbehind pattern does not have fixed length: " .. ast.tostring(a.exp), a)
	 elseif peg:find("too long") then
	    throw("lookbehind pattern too long: " .. ast.tostring(a.exp), a)
	 elseif peg:find("captures") then
	    throw("lookbehind pattern has captures: " .. ast.tostring(a.exp), a)
	 else
	    error("Internal error: " .. peg)
	 end
      end
   elseif a.type=="negation" then
      peg = (- peg)
   else
      throw("invalid predicate type: " .. tostring(a.type), a)
   end
   a.pat = pattern.new{name="predicate", peg=peg, ast=a}
   return a.pat
end


-- TODO: Make the cs_* UTF-8 AND ASCII compatible.  Essentially, change each "1" below to
-- a reference to the identifier "."


local function cs_named(a, env, prefix, messages)
   local peg = locale[a.name]
   if not peg then
      throw("unknown named charset: " .. a.name, a)
   end
   a.pat = pattern.new{name="cs_named", peg=((a.complement and 1-peg) or peg), ast=a}
   return a.pat
end

-- TODO: This impl works only for single byte chars!
local function cs_range(a, env, prefix, messages)
   local c1, offense1 = common.unescape_charlist(a.first)
   local c2, offense2 = common.unescape_charlist(a.last)
   if (not c1) or (not c2) then
      throw("invalid escape sequence in character set: \\" ..
	    (c1 and offense2) or offense1,
	 a)
   end
   local peg = R(c1..c2)
   a.pat = pattern.new{name="cs_range", peg=(a.complement and (1-peg)) or peg, ast=a}
   return a.pat
end

-- FUTURE optimization: All the single-byte chars can be put into one call to lpeg.S().
-- FUTURE optimization: The multi-byte chars can be organized by common prefix. 
function cs_list(a, env, prefix, messages)
   assert(#a.chars > 0, "empty character set list?")
   local alternatives
   for i, c in ipairs(a.chars) do
      local char, offense = common.unescape_charlist(c)
      if not char then
	 throw("invalid escape sequence in character set: \\" .. offense, a)
      end
      if not alternatives then alternatives = P(char)
      else alternatives = alternatives + P(char); end
   end -- for
   a.pat = pattern.new{name="cs_list",
		      peg=(a.complement and (1-alternatives) or alternatives),
		      ast=a}
   return a.pat
end

local cexp;

function cs_exp(a, env, prefix, messages)
   if ast.cs_exp.is(a.cexp) then
      if not a.complement then
	 -- outer cs_exp does not affect semantics, so drop it
	 return cs_exp(a.cexp, env, prefix, messages)
      else
	 -- either: inner cs_exp does not affect semantics, so drop it,
	 -- or: complement of a complement cancels out.
	 local new = ast.cs_exp{complement=(not a.cexp.complement), cexp=a.cexp.cexp, s=a.s, e=e.s}
	 return cs_exp(new, env, prefix, messages)
      end
   elseif ast.cs_union.is(a.cexp) then
      assert(#a.cexp.cexps > 0, "empty character set union?")
      local alternatives = expression(a.cexp.cexps[1], env, prefix, messages).peg
      for i = 2, #a.cexp.cexps do
	 alternatives = alternatives + expression(a.cexp.cexps[i], env, prefix, messages).peg
      end
      a.pat = pattern.new{name="cs_exp",
			 peg=((a.complement and (1-alternatives)) or alternatives),
			 ast=a}
      return a.pat
   elseif ast.cs_intersection.is(a.cexp) then
      throw("character set intersection is not implemented", a)
   elseif ast.cs_difference.is(a.cexp) then
      throw("character set difference is not implemented", a)
   elseif ast.simple_charset_p(a.cexp) then
      local p = expression(a.cexp, env, prefix, messages)
      a.pat = pattern.new{name="cs_exp", peg=((a.complement and (1-p.peg)) or p.peg), ast=a}
      return a.pat
   else
      assert(false, "compile: unknown cexp inside cs_exp", a)
   end
end

local function wrap_pattern(pat, name, optional_force_flag)
   assert(type(name)=="string")
   if pat.uncap then
      -- If pat.uncap exists, then pat.peg is already wrapped in a capture.  (N.B. The converse is
      -- NOT true for grammar expressions.) In order to wrap pat with a capture called 'name', we
      -- start with pat.uncap.  Here's an example where this happens: We must have an assignment
      -- like 'p1 = p2' where p2 is not an alias.  RPL semantics are that p1 must capture the same
      -- as p2, but the output should be labeled p1.
      pat.peg = common.match_node_wrap(pat.uncap, name)
   else      
      -- If there is no pat.uncap, then pat.peg is NOT wrapped in a capture, or pat is a grammar.
      -- In either case,  we simply wrap it with a capture called 'name'.  Here, we trap the case
      -- in which wrap_pattern is accidentally called on a grammar.
      if (not optional_force_flag) then
	 assert(not ast.grammar.is(pat.ast), 'wrap_pattern inadvertently called on a grammar')
      end
      pat.uncap = pat.peg
      pat.peg = common.match_node_wrap(pat.peg, name)
   end
end

local function throw_grammar_error(a, message)
   local maybe_rule = message:match("'%w'$")
   local rule_explanation = (maybe_rule and "in pattern "..maybe_rule.." of:") or ""
   local fmt = "%s"
   common.note("grammar: entering throw_grammar_error: " .. message)
   if message:find("may be left recursive") then
      throw(string.format(fmt, message), a)
   end
   throw("peg compilation error: " .. message, a)
end

---------------------------------------------------------------------------------------------------
-- How captures in a grammar are labeled:
---------------------------------------------------------------------------------------------------
-- A grammar introduces a new scope: the assignments made inside a grammar are not visible outside
-- the grammar.  We name the scope using the name of the grammar as a prefix.  And since there can
-- be captures named by any (non-alias) rule name, we must add the import prefix as well, in order
-- to be consistent.
--
-- I.e. a capture from package A (imported as A), grammar s, and rule c would be labeled 'A.s.c'.
-- This extra prefix layer is present only in the match output.  Much like '*' as a capture name,
-- it is not possible to refer to 'A.s.c' in RPL.  Currently, with the legacy lpeg code, it is not
-- possible to jump into the middle of a grammar -- a grammar has a unique start rule.
--
-- In RPL 1.1., the name of the start rule is used as the name of the grammar.  If the start rule
-- is named 's', it would be odd for its captures to be labeled 's.s' when they could be called
-- just 's'.  E.g. after importing package A (as A), we might see captures labeled 'A.s', 'A.s.c',
-- and 'A.s.d' if c and d were rules in s.  Note that the captures labeled 'A.s.c' and 'A.s.d' can
-- appear only as sub-matches inside 'A.s'.

-- TODO: test a grammar with two rules by the same name; who signals the error, lpeg or ???

local function grammar(a, env, prefix, messages)
   local gtable = environment.extend(env)
   local labels = {}
   assert(a.rules and a.rules[1])
   local grammar_id = a.rules[1].ref.localname
   -- First pass: Collect rule names as V() refs into a new env, and create a capture label for
   -- each one.  Also do some error checking.
   for _, rule in ipairs(a.rules) do
      assert(ast.binding.is(rule))
      assert(not rule.is_local)
      assert(not rule.ref.packagename)
      assert(type(rule.ref.localname)=="string")
      local id = rule.ref.localname
      labels[id] = (id == grammar_id) and common.compose_id{prefix, id} or common.compose_id{prefix, grammar_id, id}
      bind(gtable, id, pattern.new{name=id, peg=V(id), alias=rule.is_alias})
      common.note("grammar: binding " .. id)
   end
   -- Second pass: compile right hand sides in gtable environment
   local pats = {}
   local start
   for _, rule in ipairs(a.rules) do
      local id = rule.ref.localname
      if not start then start=id; end		    -- first rule is start rule
      common.note("grammar: compiling " .. tostring(rule.exp))
      pats[id] = expression(rule.exp, gtable, prefix, messages)
      if (not rule.is_alias) then wrap_pattern(pats[id], labels[id]); end
   end -- for
   -- Third pass: create the table that will create the LPEG grammar 
   local t = {}
   for id, pat in pairs(pats) do t[id] = pat.peg; end
   t[1] = start					    -- first rule is start rule
   local aliasflag = lookup(gtable, t[1]).alias
   local success, peg_or_msg = pcall(P, t)	    -- P(t) while catching errors
   if (not success) then
      assert(type(peg_or_msg)=="string")
      throw_grammar_error(a, peg_or_msg)
   end
   a.pat = pattern.new{name="grammar",
		      peg=peg_or_msg,
		      uncap=nil,		    -- Even if this grammar is an alias.
		      ast=a,
		      alias=aliasflag}
   return a.pat
end

-- We cannot just run peg:match("") because a lookahead expression will return nil (i.e. it will
-- not match the empty string), even though it cannot be put into a loop (because it consumes no
-- input).
local function matches_empty(peg)
   local ok, msg = pcall(function() return peg^1 end)
   return (not ok) and msg:find("loop body may accept empty string")
end

local function rep(a, env, prefix, messages)
   local epat = expression(a.exp, env, prefix, messages)
   local epeg = epat.peg
   if matches_empty(epeg) then
      throw("pattern being repeated can match the empty string", a)
   end
   a.exp.pat = epat
   if ast.atleast.is(a) then
      a.pat = pattern.new{name="atleast", peg=(epeg)^(a.min), ast=a}
   elseif ast.atmost.is(a) then
      a.pat = pattern.new{name="atmost", peg=(epeg)^(-a.max), ast=a}
   else
      assert(false, "invalid ast node dispatched to 'rep': " .. tostring(a))
   end
   return a.pat
end

local function ref(a, env, prefix, messages)
   local pat = lookup(env, a.localname, a.packagename)
   local name = common.compose_id{a.packagename, a.localname}
   if (not pat) then throw("unbound identifier: " .. name, a); end
   if not(pattern.is(pat)) then
      throw("type mismatch: expected a pattern, but '" .. name .. "' is bound to " .. tostring(pat), a)
   end
   a.pat = pattern.new{name=a.localname, peg=pat.peg, alias=pat.alias, ast=pat.ast, uncap=pat.uncap}
   return a.pat
end

-- Types: We need a string type in order to implement the 'message' function.
--   * Need a syntax to differentiate string literals from patterns that recognize strings
--     Could use #"...".  This syntax could be used for tags, which we can define as strings that
--     meet the requirements of identifiers, e.g. #foo_bar99.
--   * Or, have a macro that takes an ast.literal and returns an ast.string
--     But then we have the issue of how to reconstruct the text from the ast...
--     We would have to know that the ast.string was created by invoking a macro,
--     and display the macro invocation.
--     string:"..."  or  quote:"..."
--     This could be extended to work on patterns made from literals, providing a consistent
--     definition: The _string_ macro coerces a literal pattern to the string that it matches. 
--   * I would like to avoid implicit coercion.  So we will not silently convert "foo" (which is a
--     pattern expression) into a string when a string is called for.
--   * Implicit coercion would require static typing, anyway.
--   * But we have static typing!  It's polymorphic and not declarative:.  Given a
--     pfunction, which is itself fixed and deterministic, any invocation of that function will
--     accept some argument types and reject others --- at compile time!
--   * 

local function application(a, env, prefix, messages)
   local ref = a.ref
   local fn_ast = lookup(env, ref.localname, ref.packagename)
   local name = common.compose_id{ref.packagename, ref.localname}
   if (not ref) then throw("unbound identifier: " .. name, ref); end
   if not pfunction.is(fn_ast) then
      throw("type mismatch: expected a function, but '" .. name .. "' is bound to " .. tostring(fn_ast), a)
   end
   if not fn_ast.primop then
      assert(false, "user-defined functions are currently not supported")
   end
   common.note("applying built-in function '" .. name .. "'")
   local operands = list.map(function(exp)
				return expression(exp, env, prefix, messages)
			     end,
			     a.arglist)
   local ok, peg, uncap = pcall(fn_ast.primop, table.unpack(operands))
   if not ok then
      throw("error in function: '" .. tostring(peg), a)
   end
   a.pat = pattern.new{name=name, peg=peg, ast=a, uncap=uncap}
   return a.pat
end

local dispatch = { [ast.string] = rpl_string,
		   [ast.hashtag] = hashtag,
		   [ast.literal] = literal,
		   [ast.sequence] = sequence,
		   [ast.choice] = choice,
		   [ast.ref] = ref,
		   [ast.cs_exp] = cs_exp,
		   [ast.cs_named] = cs_named,
		   [ast.cs_range] = cs_range,
		   [ast.cs_list] = cs_list,
		   [ast.atmost] = rep,
		   [ast.atleast] = rep,
		   [ast.predicate] = predicate,
		   [ast.grammar] = grammar,
		   [ast.application] = application,
		}

-- The forward reference for 'expression' declares it to be local
function expression(a, env, prefix, messages)
   local compile = dispatch[parent(a)]
   if (not compile) then
      throw("invalid expression: " .. tostring(a), a)
   end
   a.pat = compile(a, env, prefix, messages)
   return a.pat
end

local function compile_expression(exp, env, prefix, messages)
   local ok, value, err = apply_catch(expression, exp, env, prefix, messages)
   if not ok then
      local full_message = "error in compile_expression:" .. tostring(value) .. "\n"
      for _,v in ipairs(messages) do
	 full_message = full_message .. tostring(v) .. "\n"
      end
      assert(false, full_message)
   elseif not value then
      assert(parent(err))
      table.insert(messages, err)		    -- enqueue violation object
      return false
   end
   return value
end

-- 'c2.compile_expression' compiles a top-level expression for matching.  If the expression is
-- simply a reference, the match output will have the name of the referenced pattern.  If the
-- expression is a reference to an alias, or if the expression is not a reference at all, then the
-- match output will have the name "*" (meaning "anonymous") at the top level.
function c2.compile_expression(a, env, messages)
   local pat = compile_expression(a, env, nil, messages)
   if not pat then return false; end		    -- error will be in messages
   if pat and (not pattern.is(pat)) then
      local msg =
	 "type error: expression did not compile to a pattern, instead got " .. tostring(pat)
      table.insert(messages,
		   violation.compile.new{who='expression compiler', message=msg, ast=a})
      return false
   end
   local peg, name = pat.peg, pat.name
   if ast.ref.is(a) then
      if pat.alias then
	 pat.peg = common.match_node_wrap(pat.peg, "*")
      end
   else -- not a reference
      wrap_pattern(pat, "*", true)		    -- force wrap, even if pat is a grammar
   end
   pat.alias = false
   return pat
end

---------------------------------------------------------------------------------------------------
-- Compile block
---------------------------------------------------------------------------------------------------

-- Compile all the statements in the block.  Any imports were loaded during the syntax expansion
-- phase, in order to access macro definitions.
function c2.compile_block(a, pkgenv, request, messages)
   assert(ast.block.is(a))
   assert(environment.is(pkgenv))
   assert(request==nil or common.loadrequest.is(request))
   assert(type(messages)=="table")
   local prefix
   if request and request.importpath and (request.prefix~=".") then
      assert(request.packagename==nil or type(request.packagename)=="string")
      assert(request.prefix==nil or type(request.prefix=="string"))
      prefix = request.prefix or request.packagename
   end
   -- Step 1: For each lhs, bind the identifier to 'novalue'.
   -- TODO: Ensure each lhs appears only once in a.stmts.
   for _, b in ipairs(a.stmts) do
      assert(ast.binding.is(b))
      local ref = b.ref
      assert(not ref.packagename)
      if environment.lookup(pkgenv, ref.localname) then
	 common.note("Rebinding " .. ref.localname)
      else
	 common.note("Creating initial binding for " .. ref.localname)
      end
      bind(pkgenv, ref.localname, novalue.new{exported=true, ast=b})
   end -- for
   -- Step 2: Compile the rhs (expression) for each binding.  
   -- TODO: If an exp depends on a 'novalue', return 'novalue'.
   -- TODO: Repeat step 2 until either every lhs is bound to an actual value (or error), or an
   --       entire pass through a.stmts fails to change any binding.
   for _, b in ipairs(a.stmts) do
      local ref, exp = b.ref, b.exp
      local pat = compile_expression(exp, pkgenv, prefix, messages)
      if pat then 
	 -- TODO: need a proper error message
	 if type(pat)~="table" then
	    io.stderr:write("    BUT DID NOT GET A PATTERN: ", tostring(pat), "\n")
	 end
	 -- Sigh.  Grammars are already wrapped.  This is ugly.
	 if (not b.is_alias) and (not ast.grammar.is(exp)) then
	    local fullname = common.compose_id{prefix, ref.localname}
	    wrap_pattern(pat, fullname);
	 end
	 pat.alias = b.is_alias
	 if b.is_local then pat.exported = false; end
	 common.note("Binding value to " .. ref.localname)
	 bind(pkgenv, ref.localname, pat)
      else
	 return false
      end
   end -- for

   -- Step 3: 

   return true
end

return c2
