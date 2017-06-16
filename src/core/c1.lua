-- -*- Mode: Lua; -*-                                                                             
--
-- c1.lua    rpl compiler internals for rpl 1.1
--
-- © Copyright IBM Corporation 2017.
-- LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)
-- AUTHOR: Jamie A. Jennings

local c1 = {}
local c0 = require "c0"

local string = require "string"
local lpeg = require "lpeg"
local common = require "common"
local pattern = common.pattern
local pfunction = common.pfunction
local decode_match = common.decode_match
local violation = require "violation"
local throw = violation.throw

function c1.process_package_decl(typ, pos, text, subs, fin)
   assert(typ=="package_decl")
   local typ, pos, text = decode_match(subs[1])
   assert(typ=="packagename")
   common.note("In package " .. text)
   return text					    -- return package name
end

function c1.compile_local(ast, gmr, source, env)
   assert(not gmr, "the rpl grammar allowed a local decl inside a grammar???")
   local typ, _, _, subs = decode_match(ast)
   assert(typ=="local_")
   local name, pos, text = decode_match(subs[1])
   local pat = c0.compile_ast(subs[1], source, env)
   pat.exported = false;
   return pat
end

function c1.compile_ast(ast, env)
   assert(type(ast)=="table", "Compiler: first argument not an ast: "..tostring(ast))
   local functions = {"compile_ast";
		      local_ = c1.compile_local;
		      binding=c0.compile_binding;
		      new_grammar=c0.compile_grammar;
		      exp=c0.compile_exp;
		      default=c0.compile_exp;
		   }
   return common.walk_parse_tree(ast, functions, false, env)
end

function c1.expression_p(ast)
   local name, pos, text, subs = decode_match(ast)
   return not (not (name=="application" or
		    name=="int" or
		    c0.compile_exp_functions[name]))
end

----------------------------------------------------------------------------------------
-- Coroutine body
----------------------------------------------------------------------------------------

-- Note: a 'package' is the run-time instantiation of an RPL 'module'.
-- 
-- The load procedure enforces the structure of an rpl module:
--     rpl_module = language_decl? package_decl? import_decl* statement* ignore
--
-- We could parse a module using that rpl_module pattern, but we can give better
-- error messages this way.
--
-- The load procedure compiles in a fresh environment (creating new bindings there) UNLESS
-- importpath is nil, which indicates "top level" loading into env.  Each dependency must already
-- be compiled and have an entry in pkgtable, else the compilation will fail.
--
-- importpath: a relative filesystem path to the source file, or nil
-- ast: the already preparsed, parsed, and expanded input to be compiled
-- pkgtable: the global package table (one per engine) because modules can be shared
-- 
-- Return values are success, packagename/nil, table of messages

function c1.load(importpath, ast, pkgtable, env)
   assert(type(importpath)=="string" or importpath==nil)
   assert(type(ast)=="table" and (ast.subs==nil or type(ast.subs)=="table"))
   assert(type(pkgtable)=="table")
   assert(environment.is(env))
   local astlist = ast.subs or {}
   local thispkg
   local i = 1
   if not astlist[i] then
      return true, nil, {violation.warning.new{who="load", message="Empty input", ast=ast}}
   end
   local typ, pos, text, subs, fin = common.decode_match(astlist[i])
   assert(typ~="language_decl", "language declaration should be handled in preparse/parse")
   if typ=="package_decl" then
      thispkg = c1.process_package_decl(typ, pos, text, subs, fin)
      i=i+1;
      if not astlist[i] then
	 return true,
	        thispkg,
	        {violation.warning.new{who="load",
				       message="Empty module (nothing after package declaration)",
				       ast=ast}}
      end
      typ, pos, text, subs, fin = common.decode_match(astlist[i])
   end
   -- If there is a package_decl, then this code is a module.  It gets its own fresh
   -- environment, and it is registered (by its importpath) in the per-engine pkgtable.
   -- Otherwise, if there is no package decl, then the code is compiled in the default, or
   -- "top level" environment.  
   if thispkg then
      assert(not common.pkgtableref(pkgtable, importpath),
	     "module " .. importpath .. " already compiled and loaded?")
   end
   -- Dependencies must have been compiled and imported before we get here, so we can skip over
   -- the import declarations.
   while typ=="import_decl" do
      i=i+1
      if not astlist[i] then
	 return true,
	    thispkg,
	    {violation.info.new{who="load",
				message="Module consists only of import declarations",
				ast=ast}}
      end
      typ, pos, text, subs, fin = common.decode_match(astlist[i])
   end -- while skipping import_decls
   local results, messages = {}, {}
   repeat
      results[i], message = c1.compile_ast(astlist[i], env)
      if message then table.insert(messages, message); end
      i=i+1
   until not astlist[i]
   -- success! save this env in the pkgtable, if we have an importpath.
   if importpath and thispkg then common.pkgtableset(pkgtable, importpath, thispkg, env); end
   return true, thispkg, messages
end


return c1
