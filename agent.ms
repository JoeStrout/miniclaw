import "importUtil"
ensureImport ["json", "grfon", "stringUtil", "mapUtil", "dateTime", "styledText"]
ensureImport "tools"

EOL = char(10)

// Helper function to prompt the user that there is more output,
// and wait for their response.  Return true to continue, or
// false to cancel further output.
pauseForMore = function
	text.inverse = true; print "[more]", ""; text.inverse = false
	bail = false
	while not bail
		k = key.get
		ikey = code(k)
		if ikey == 27 or k == "q" or k == "Q" then bail = true
		if ikey == 10 or ikey == 13 or ikey == 3 or k == " " then break
		yield
	end while
	text.column = 0; print " " * 7, ""; text.column = 0
	return not bail
end function


// Make a custom version of TextPrinter.printStyleRuns that pauses every
// 25 lines, similar to `dir` and `pageThrough` (in startup.ms).  (Also,
// it ignores Printer.y and just prints line by line.)  Returns new
// number of lines till we should pause.
MyTextPrinter = new styledText.TextPrinter
MyTextPrinter.printStyleRuns = function(runs, linesTillPause = 24)
	text.column = self.x
	if self.wrapTo == null then self.wrapTo = text.column
	if linesTillPause < 1 then
		if not pauseForMore then return 24
		linesTillPause = 24
	end if
	for styleRun in runs
		self.applyStyle styleRun
		while self.wrapAt - text.column < styleRun.text.len
			partialText = self.cutToFit(styleRun, 
			  self.wrapAt - text.column, text.column <= self.wrapTo)
			text.print partialText
			text.column = self.wrapTo
			linesTillPause -= 1
			if linesTillPause < 1 then
				if not pauseForMore then break
				linesTillPause = 24
			end if
		end while
		text.print styleRun.text, ""
		self.restore
	end for
	text.print
	linesTillPause -= 1
	self.x = self.wrapTo
	return linesTillPause
end function

// And fix a bug in the current release version (ignores code style):
MyTextPrinter.applyStyle = function(style)
	super.applyStyle style
	if style.code then text.color = self.color.code
end function
MyTextPrinter.color.code = color.aqua
MyTextPrinter.wrapAt = 67

// Get the "instructions" part of the prompt from a file.
// (These are always the same.)
instructions = file.readLines("/usr/instructions.txt").join(EOL)

// Globals for the current user input, and response history.
currentUserInput = ""
history = []
historyLen = 0  // (sum of the length of all history entries)
lastMessage = ""

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
	printer = new MyTextPrinter
	printer.color.normal = textColor
	linesTillPause = 24
	for line in cleanText(s).split(EOL)
		runs = styledText.parseMarkup(line)
		linesTillPause = printer.printStyleRuns(runs, linesTillPause)
	end for
end function

// Determine whether two strings are largely the same.
verySimilar = function(s1, s2)
	if s1.len > s2.len*1.25 or s2.len > s1.len*1.25 then return false
	return s1.editDistance(s2) / s1.len < 0.1
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
		globals.lastMessage = data.content
	else if data.type == "question" then
		printNicely data.content
		text.color = color.gray; print "==> ", ""
		text.color = "#00AA00"
		addToHistory ["", "--- User response ---", input, "--- End user response ---"].join(EOL)
		text.color = color.gray
	else if data.type == "finish" then
		// Sometimes the LLM repeats its last message (from "message")
		// in the "finish" output, I guess when it realizes it has no more
		// to say.  Detect this and suppress the redundant output.
		if not verySimilar(data.content, lastMessage) then
			printNicely data.content
		end if
		globals.currentUserInput = ""
	else if data.type == "tool_call" then
		handleToolCall data
	else
		addToHistory "ERROR: invalid response type """ + data.type +
		  """; must be ""message"", ""question"", ""finish"", or ""tool_call""."
	end if	
end function

// Handle a tool all.  The data here is the same map passed to handleResponse,
// but separated out into its own method so we can focus on this common case.
handleToolCall = function(data)
	toolName = data.get("tool", "(undefined)")
	s = "Invoking " + toolName
	if data.hasIndex("reason") then s += ": " + data.reason
	text.color = color.gray
	print s
	args = data.get("arguments", {})
	//print args
	if tools.hasIndex(toolName) then
		f = @tools[toolName]
		result = f(args)
		addToHistory jsonify(data)
		addToHistory jsonify(result)
	else
		addToHistory tools.err("Unknown tool `" + toolName + "`")
	end if
end function

// Main loop: Ask the user for instructions when needed; otherwise
// keep calling the model with the results of its tool uses, updating
// history accordingly.
mainLoop = function
	if not file.exists("/usr/workspace") then file.makedir("/usr/workspace")
	clear
	text.color = color.orange
	print "Hi!  How can I help you today?"
	while true
		if not currentUserInput then
			text.color = color.gray; print "==> ", ""
			text.color = "#00AA00"
			globals.currentUserInput = input
			text.color = color.gray
		end if
		response = getResponse
		respData = json.parse(response)
		if respData == null then
			addToHistory("**IMPORTANT:** You must format your response as a JSON object!")
		else
			handleResponse respData
		end if
	end while
end function

if locals == globals then mainLoop
