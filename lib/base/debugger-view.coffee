{Point, Range, TextEditor, TextBuffer, CompositeDisposable} = require 'atom'
{View} = require 'atom-space-pen-views'
GDB = require '../backend/gdb/gdb'
fs = require 'fs'
path = require 'path'
AsmViewer = require '../asm-viewer'

module.exports =
class DebuggerView extends View
  @content: ->
    @div class: 'atom-debugger', =>
      @header class: 'header', =>
        @span class: 'header-item title', 'Atom Debugger'
        @span class: 'header-item sub-title', outlet: 'targetLable'
      @div class: 'btn-toolbar', =>
        @div class: 'btn-group', =>
          @div class: 'btn', outlet: 'runButton', 'Run'
          @div class: 'btn disabled', outlet: 'continueButton', 'Continue'
          @div class: 'btn disabled', outlet: 'interruptButton', 'Interrupt'
          @div class: 'btn disabled', outlet: 'nextButton', 'Next'
          @div class: 'btn disabled', outlet: 'stepButton', 'Step'

  initialize: (target, mainBreak) ->
    @GDB = new GDB(target)
    @targetLable.text(target)

    @GDB.set 'target-async', 'on', (result) ->
    @GDB.setSourceDirectories atom.project.getPaths(), (done) ->

    @breaks = {}
    @breakPoints = [];
    @stopped = {marker: null, fullpath: null, line: null}
    @asms = {}
    @cachedEditors = {}
    @handleEvents()

    contextMenuCreated = (event) =>
      if editor = @getActiveTextEditor()
        component = atom.views.getView(editor).component
        position = component.screenPositionForMouseEvent(event)
        @contextLine = editor.bufferPositionForScreenPosition(position).row

    @menu = atom.contextMenu.add {
      'atom-text-editor': [{
        label: 'Toggle Breakpoint',
        command: 'KuttiDebugger:toggle-breakpoint',
        created: contextMenuCreated
      }]
    }

    @panel = atom.workspace.addBottomPanel(item: @, visible: true)

    @loadBreakPoints()
    @listExecFile()

  getActiveTextEditor: ->
    atom.workspace.getActiveTextEditor()

  exists: (fullpath) ->
    return fs.existsSync(fullpath)

  getEditor: (fullpath) ->
    return @cachedEditors[fullpath]

  goExitedStatus: ->
    @continueButton.addClass('disabled')
    @interruptButton.addClass('disabled')
    @stepButton.addClass('disabled')
    @nextButton.addClass('disabled')
    @removeClass('running')
    @addClass('stopped')

  goStoppedStatus: ->
    @continueButton.removeClass('disabled')
    @interruptButton.addClass('disabled')
    @stepButton.removeClass('disabled')
    @nextButton.removeClass('disabled')
    @removeClass('running')
    @addClass('stopped')

  goRunningStatus: ->
    @stopped.marker?.destroy()
    @stopped = {marker: null, fullpath: null, line: null}
    @continueButton.addClass('disabled')
    @interruptButton.removeClass('disabled')
    @stepButton.addClass('disabled')
    @nextButton.addClass('disabled')
    @removeClass('stopped')
    @addClass('running')

  insertMainBreak: ->
    @GDB.insertBreak {location: 'main'}, (abreak) =>
      if abreak
        fullpath = path.resolve(abreak.fullname)
        line = Number(abreak.line)-1
        @insertBreakWithoutEditor(fullpath, line)

  listExecFile: ->
    @GDB.listExecFile (file) =>
      if file
        fullpath = path.resolve(file.fullname)
        line = Number(file.line) - 1
        if @exists(fullpath)
          atom.workspace.open fullpath, (editor) =>
            @moveToLine(editor, line)
        else
          atom.confirm
            detailedMessage: "Can't find file #{file.file}\nPlease add path to tree-view and try again."
            buttons:
              Exit: => @destroy()

  toggleBreak: (editor, line) ->
    if @hasBreak(editor, line)
      @deleteBreak(editor, line)
    else
      @insertBreak(editor, line)

  hasBreak: (editor, line) ->
    return line of @breaks[editor.getPath()]

  deleteBreak: (editor, line) ->
    fullpath = editor.getPath()
    {abreak, marker} = @breaks[fullpath][line]
    @GDB.deleteBreak abreak.number, (done) =>
      if done
        marker.destroy()
        delete @breaks[fullpath][line]
        for breakPoint, i in @breakPoints
          if breakPoint.path == fullpath && breakPoint.line == line
            @breakPoints = @breakPoints.splice(i, 1);
            break

  insertBreakForLocation :(fullPath,line,handler) ->
    @GDB.insertBreak {location: "#{fullPath}:#{line+1}"}, (abreak) =>
      if abreak
        editor = @getEditor(fullPath)
        marker = @markBreakLine(editor, line)
        @breaks[fullPath][line] = {abreak, marker}
        @breakPoints ?=[]
        @breakPoints.push({path:fullPath,line:line});
        handler(abreak)

  insertBreak: (editor, line) ->
    fullPath = editor.getPath()
    @insertBreakForLocation fullPath, line, (abreak) =>
      @saveBreakPoints()

  saveBreakPoints: ->
    @BreakPointsFile = atom.project.getPaths()[0] + "/.atomBreakPoints"
    jsonStringForBreakPoints = JSON.stringify(@breakPoints);
    fs.writeFile @BreakPointsFile, jsonStringForBreakPoints, (err)=>
      if err
        console.log("Error saving Breakpoints"+err);
    console.log("Saving Breakpoints");

  loadBreakPoints: ->
    @BreakPointsFile = atom.project.getPaths()[0] + "/.atomBreakPoints"
    fs.readFile @BreakPointsFile,'utf8', (err,data)=>
      if(err)
        console.log("Error reading breakpoints file")
      else
        @breakPoints = JSON.parse(data)
        for breakPoint, i in @breakPoints
          @insertBreakForLocation breakPoint.path, breakPoint.line, =>

  insertBreakWithoutEditor: (fullpath, line) ->
    @breaks[fullpath] ?= {}
    @GDB.insertBreak {location: "#{fullpath}:#{line+1}"}, (abreak) =>
      if abreak
        if editor = @getEditor(fullpath)
          marker = @markBreakLine(editor, line)
        else
          marker = null
        @breaks[fullpath][line] = {abreak, marker}

  moveToLine: (editor, line) ->
    editor.scrollToBufferPosition(new Point(line))
    editor.setCursorBufferPosition(new Point(line))
    editor.moveToFirstCharacterOfLine()

  markBreakLine: (editor, line) ->
    range = new Range([line, 0], [line+1, 0])
    marker = editor.markBufferRange(range, {invalidate: 'never'})
    editor.decorateMarker(marker, {type: 'line-number', class: 'debugger-breakpoint-line'})
    return marker

  markStoppedLine: (editor, line) ->
    range = new Range([line, 0], [line+1, 0])
    marker = editor.markBufferRange(range, {invalidate: 'never'})
    editor.decorateMarker(marker, {type: 'line-number', class: 'debugger-stopped-line'})
    editor.decorateMarker(marker, {type: 'highlight', class: 'selection'})

    @moveToLine(editor, line)
    return marker

  refreshBreakMarkers: (editor) ->
    fullpath = editor.getPath()
    for line, {abreak, marker} of @breaks[fullpath]
      marker = @markBreakLine(editor, Number(line))
      @breaks[fullpath][line] = {abreak, marker}

  refreshStoppedMarker: (editor) ->
    fullpath = editor.getPath()
    if fullpath == @stopped.fullpath
      @stopped.marker = @markStoppedLine(editor, @stopped.line)

  hackGutterDblClick: (editor) ->
    component = atom.views.getView(editor).component
    # gutterComponent has been renamed to gutterContainerComponent
    gutter  = component.gutterComponent
    gutter ?= component.gutterContainerComponent

    gutter.domNode.addEventListener 'dblclick', (event) =>
      position = component.screenPositionForMouseEvent(event)
      line = editor.bufferPositionForScreenPosition(position).row
      @toggleBreak(editor, line)
      selection = editor.selectionsForScreenRows(line, line + 1)[0]
      selection.clear()

  handleEvents: ->
    @subscriptions = new CompositeDisposable

    @subscriptions.add atom.commands.add 'atom-workspace', 'KuttiDebugger:toggle-breakpoint': =>
      @debuggerView.toggleBreak(@getActiveTextEditor(), @contextLine)

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      fullpath = editor.getPath()
      @cachedEditors[fullpath] = editor
      @breaks[fullpath] ?= {}
      @refreshBreakMarkers(editor)
      @refreshStoppedMarker(editor)
      @hackGutterDblClick(editor)

    @subscriptions.add atom.project.onDidChangePaths (paths) =>
      @GDB.setSourceDirectories paths, (done) ->

    @runButton.on 'click', =>
      @GDB.run (result) ->

    @continueButton.on 'click', =>
      @GDB.continue (result) ->

    @interruptButton.on 'click', =>
      @GDB.interrupt (result) ->

    @nextButton.on 'click', =>
      @GDB.next (result) ->

    @stepButton.on 'click', =>
      @GDB.step (result) ->

    @GDB.onExecAsyncRunning (result) =>
      @goRunningStatus()

    @GDB.onExecAsyncStopped (result) =>
      @goStoppedStatus()

      unless frame = result.frame
        @goExitedStatus()
      else
        fullpath = path.resolve(frame.fullname)
        line = Number(frame.line)-1

        if @exists(fullpath)
          atom.workspace.open(fullpath, {debugging: true, fullpath: fullpath, startline: line}).done (editor) =>
            @stopped = {marker: @markStoppedLine(editor, line), fullpath, line}
        else
          @GDB.next (result) ->

  # Tear down any state and detach
  destroy: ->
    @GDB.destroy()
    @subscriptions.dispose()
    @stopped.marker?.destroy()
    @menu.dispose()

    for fullpath, breaks of @breaks
      for line, {abreak, marker} of breaks
        marker.destroy()

    for editor in atom.workspace.getTextEditors()
      component = atom.views.getView(editor).component
      gutter  = component.gutterComponent
      gutter ?= component.gutterContainerComponent
      gutter.domNode.removeEventListener 'dblclick'

    @panel.destroy()
