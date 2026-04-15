import "importUtil"
ensureImport ["json", "grfon", "stringUtil", "mapUtil", "dateTime"]
ensureImport "tools"

EOL = char(10)

// Get the "instructions" part of the prompt from a file.
// (These are always the same.)
instructions = file.readLines("/usr/instructions.txt").join(EOL)

// Globals for the current user input, and response history.
currentUserInput = ""
history = []
historyLen = 0  // (sum of the length of all history entries)

// Get the API key from our secret file.
apiKey = function
	print "Reading API key from file"
	outer.apiKey = file.readLines("/usr/api_key.secret")[0]
	return apiKey
end function

// Add something to our history, and if it's getting too long,
// forget some of the older stuff.
addToHistory = function(entry)
	history.push entry
	globals.historyLen += entry.len
	while historyLen > 4096 and history.len > 8
		globals.historyLen -= history[0].len
		history.pull
	end while
end function

// Build the "input" part of the prompt from our current status,
// including the currentUserInput and history globals.
promptInput = function
	lines = []
	lines.push "# Task/User Input"
	lines.push currentUserInput
	lines.push ""
	lines.push "# Current State"
	lines.push "Date/time: " + dateTime.now
	if history then
		lines.push ""
		lines.push "# Recent history"
		lines += history
	end if
	return lines.join(EOL)
end function

// Convert the given map to JSON, but watch for special strings
// "<true>" and "<false>", and convert those to plain true and 
// false values.  (We can't easily represent those otherwise since
// true and false in MiniScript are just numeric 1 and 0.)
jsonify = function(data)
	result = json.toJSON(data)
	result = result.replace("""<true>""", "true")
	result = result.replace("""<false>""", "false")
	return result
end function

// Call the model and return the text of its response.  This should be
// JSON data of one of the types defined in instructions.txt.
getResponse = function(prompt, temperature=0.5)
	// Details here are specific to OpenAI.  
	// Other LLM providers will have different setup and response formats.
	url = "https://api.openai.com/v1/responses"
	globals.headers = {}
	headers["Content-Type"] = "application/json"
	headers.Authorization = "Bearer " + apiKey
	data = {}
	data.model = "gpt-5.4-nano"
	data.instructions = instructions
	data.input = promptInput
	data.temperature = 0.4
	data.store = "<false>"  // shenanigans; see replace, below

	print "Calling " + url + "..."
	globals.rawResult = http.post(url, jsonify(data), headers)
	print "Got " + len(rawResult) + " characters response"
	if rawResult.len < instructions.len then print rawResult
	result = json.parse(rawResult)
	// Dig the actual response out of the surrounding junk:
	bestOutput = null
	for output in result.output
		if not bestOutput or output.phase == "final_answer" then
			bestOutput = output
		end if
	end for
	return bestOutput.content[0].text
end function

// Replace some fancy (non-ASCII) characters the LLM is wont to use.
cleanText = function(s)
	s = s.replace("—", "--")
	s = s.replace("’", "'")
	s = s.replace("‘", "'")
	s = s.replace("“", """")
	s = s.replace("”", """")
	return s
end function

// Print a possibly long response, with text wrapping and paging.
printNicely = function(s, textColor="#FF8000")
	text.color = textColor
	if s isa list then lines = s else lines = s.split(EOL)
	for i in range(lines.len-1, 0, -1)
		lines = lines[:i] + lines[i].wrap + lines[i+1:]
	end for
	for i in lines.indexes; lines[i] = cleanText(lines[i]); end for
	pageThrough lines
end function

// Handle a response, given as a dictionary with "type" etc.
// as defined in instructions.txt.
handleResponse = function(data)
	if not data isa map then
		print "Got something other than a map in handleResponse: " + data
		pprint stackTrace
		exit
	end if
	addToHistory data
	if not data.hasIndex("type") then
		addToHistory "ERROR: response must be a JSON object with `type` per your instructions."
	else if data.type == "message" then
		printNicely data.content
	else if data.type == "question" then
		printNicely data.content
		text.color = color.gray; print "==> ", ""
		text.color = color.green
		addToHistory ["", "--- User response ---", input, "--- End user response ---"].join(EOL)
	else if data.type == "finish" then
		printNicely data.content, color.yellow
		globals.currentUserInput = ""
	else if data.type == "tool_call" then
		handleToolCall data
	else
		addToHistory "ERROR: invalid response type """ + data.type +
		  """; must be ""message"", ""question"", ""finish"", or ""tool_call""."
	end if	
end function

handleToolCall = function(data)
	toolName = data.get("tool", "(undefined)")
	s = "Invoking " + toolName
	if data.hasIndex("reason") then s += ": " + data.reason
	text.color = color.gray
	print s
	args = data.get("arguments", {})
	print args
	if tools.hasIndex(toolName) then
		f = @tools[toolName]
		result = f(args)
		addToHistory jsonify(data)
		addToHistory jsonify(result)
	else
		addToHistory tools.err("Unknown tool `" + toolName + "`")
		print history[-1]
		exit
	end if
end function

// Main loop: Ask the user for instructions when needed; otherwise
// keep calling the model with the results of its tool uses, updating
// history accordingly.
mainLoop = function
	while true
		if not currentUserInput then
			text.color = color.gray; print "==> ", ""
			text.color = color.green
			globals.currentUserInput = input
			text.color = color.gray
		end if
		response = getResponse
		respData = json.parse(response)
		handleResponse respData
	end while
end function

clear
if locals == globals then mainLoop
