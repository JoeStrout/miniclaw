// This module defines tools that can be invoked by the agent.
// Each tool is a function which takes the arguments as a map.
// Tools here must match the definitions given in instructions.txt,
// and return a dictionary that is convertible to JSON.

import "importUtil"
ensureImport "mapUtil"

err = function(message)
	return { "ok": "<false>", "error": message }
end function

errMissingArg = function(param)
	return err("Missing required parameter `" + param + "`")
end function

// Resolve a path that may contain ".." or "." or be a relative
// path, to a simple absolute path.
resolvePath = function(path)
	info = file.info(path)
	if info == null then
		// file doesn't exist, but maybe the parent does?
		info = file.info(file.parent(path))
		if info then return file.child(info.path, file.name(path))
		return null
	end if
	return info.path
end function

isWriteable = function(path)
	path = resolvePath(path)
	info = file.info(path)
	if info then info.path.startsWith("/usr/workspace/")
	parentInfo = file.info(file.parent(path))
	if parentInfo then
		return parentInfo.path == "/usr/workspace" or parentInfo.path.startsWith("/usr/workspace/")
	end if
	return false
end function	

okResult = function
	return { "ok": "<true>" }
end function

//  {
//    "name": "list_files",
//    "desc": "Return a list of files under the given directory path."
//    "arguments": { "path": "string" }
//  }
list_files = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	names = file.children(path)
	if names == null then return err("Invalid path `" + path + "`")
	result = okResult
	result.files = []
	for name in names
		info = file.info(file.child(path, name))
		info.remove "comment"  // (never anythnig useful here anyway)
		result.files.push info
	end for
	return result
end function


//  {
//    "name": "read_file",
//    "desc": "Return a UTF-8 file.  Use this before editing an existing file."
//    "arguments": { "path": "string" }
//  },
read_file = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	if not file.exists(path) then return err("Invalid path `" + path + "`")
	data = file.readLines(path)
	result = okResult
	result.path = path
	result.lines = data.len
	result.content = data.join(EOL)
	return result
end function

//  {
//    "name": "head_file",
//    "desc": "Return the first n lines of a UTF-8 file.  Use this to examine large or unknown text files."
//    "arguments": { "path": "string", "lines": "int" }
//  },
head_file = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	lines = args.get("lines", 10)
	if not file.exists(path) then return err("Invalid path `" + path + "`")
	data = file.readLines(path)
	if data.len > lines then data = data[:lines]
	result = okResult
	result.path = path
	result.content = data.join(EOL)
	return result
end function

//  {
//    "name": "tail_file",
//    "desc": "Return the last n lines of a UTF-8 file.  Use to inspect the end of a file without reading the whole thing."
//    "arguments": { "path": "string", "lines": "int" }
//  },
tail_file = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	lines = args.get("lines", 10)
	if not file.exists(path) then return err("Invalid path `" + path + "`")
	data = file.readLines(path)
	if data.len > lines then data = data[-lines:]
	result = okResult
	result.path = path
	result.content = data.join(EOL)
	return result
end function

//  {
//    "name": "write_file",
//    "desc": "Write a file to the given path.  If the file exists, it is overwritten.  Use with caution."
//    "arguments": { "path": "string", "content": "string" }
//  },
write_file = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	if not args.hasIndex("content") then return errMissingArg("content")
	content = args.content
	path = resolvePath(path)
	if not path then return err("Invalid path `" + path + "`")
	if not isWriteable(path) then return err("Unwriteable path `" + path + "`")
	f = file.open(path, "w")
	f.write content
	f.close
	result = okResult
	result.path = path
	result.bytes_written = file.info(path).size
	return result
end function

//  {
//    "name": "delete_file",
//    "desc": "Delete a file from the file system.  Use with caution."
//    "arguments": { "path": "string" }
//  },
delete_file = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	if not file.exists(path) then return err("File not found: `" + path + "`")
	path = resolvePath(path)
	if not path then return err("Invalid path `" + path + "`")
	if not isWriteable(path) then return err("Unwriteable path `" + path + "`")
	file.delete path
	result = okResult
	result.path = path
	return result
end function

//  {
//    "name": "move_file",
//    "desc": "Move or rename a file. dest_path may be a full path or just a target directory. Fails if there is an existing file where the moved file would go."
//    "arguments": { "src_path": "string", "dest_path": "string" }
//  },
move_file = function(args)
	src_path = args.get("src_path"); if not src_path then return errMissingArg("src_path")
	dest_path = args.get("dest_path"); if not dest_path then return errMissingArg("dest_path")
	if not file.exists(src_path) then return err("File not found: `" + src_path + "`")
	srcInfo = file.info(src_path)
	dest_path = resolvePath(path)
	if not dest_path then return err("Invalid path `" + dest_path + "`")
	if not isWriteable(dest_path) then return err("Unwriteable path `" + dest_path + "`")
	// If dest exists and is a file (not a directory), refuse to overwrite
	if file.exists(dest_path) and not file.info(dest_path).isDirectory then
		return err("Destination already exists: `" + dest_path + "`")
	end if
	file.move src_path, dest_path
	result = okResult
	result.path = dest_path
	return result
end function

//  {
//    "name": "make_dir",
//    "desc": "Create a directory at the given path."
//    "arguments": { "path": "string" }
//  },
make_dir = function(args)
	path = args.get("path"); if not path then return errMissingArg("path")
	path = resolvePath(path)
	if not path then return err("Invalid path `" + path + "`")
	if not isWriteable(path) then return err("Unwriteable path `" + path + "`")
	if file.exists(path) then return err("Path already exists: `" + path + "`")
	file.makedir path
	result = okResult
	result.path = path
	return result
end function
