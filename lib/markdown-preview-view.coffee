path = require 'path'

{Emitter, Disposable, CompositeDisposable, File} = require 'atom'
_ = require 'underscore-plus'
fs = require 'fs-plus'

renderer = require './renderer'

module.exports =
class MarkdownPreviewView
  @deserialize: (params) ->
    new MarkdownPreviewView(params)

  constructor: ({@editorId, @filePath}) ->
    @element = document.createElement('div')    
    @element.classList.add('markdown-preview', 'native-key-bindings')
    @element.tabIndex = -1
    @emitter = new Emitter
    @loaded = false
    @disposables = new CompositeDisposable
    @registerScrollCommands()
    if @editorId?
      @resolveEditor(@editorId)
    else if atom.workspace?
      @subscribeToFilePath(@filePath)
    else
      @disposables.add atom.packages.onDidActivateInitialPackages =>
        @subscribeToFilePath(@filePath)

  serialize: ->
    deserializer: 'MarkdownPreviewView'
    filePath: @getPath() ? @filePath
    editorId: @editorId

  destroy: ->
    @disposables.dispose()
    @element.remove()

  registerScrollCommands: ->
    @disposables.add(atom.commands.add(@element, {
      'core:move-up': =>
        @element.scrollTop -= window.offsetHeight / 20
        return
      'core:move-down': =>
        @element.scrollTop += window.offsetHeight / 20
        return
      'core:page-up': =>
        @element.scrollTop -= @element.offsetHeight
        return
      'core:page-down': =>
        @element.scrollTop += @element.offsetHeight
        return
      'core:move-to-top': =>
        @element.scrollTop = 0
        return
      'core:move-to-bottom': =>
        @element.scrollTop = @element.scrollHeight
        return
    }))
    return

  onDidChangeTitle: (callback) ->
    @emitter.on 'did-change-title', callback

  onDidChangeModified: (callback) ->
    # No op to suppress deprecation warning
    new Disposable

  onDidChangeMarkdown: (callback) ->
    @emitter.on 'did-change-markdown', callback

  subscribeToFilePath: (filePath) ->
    @file = new File(filePath)
    @emitter.emit 'did-change-title'
    @disposables.add @file.onDidRename(=> @emitter.emit 'did-change-title')
    @handleEvents()
    @renderMarkdown()

  resolveEditor: (editorId) ->
    resolve = =>
      @editor = @editorForId(editorId)

      if @editor?
        @emitter.emit 'did-change-title'
        @disposables.add @editor.onDidDestroy(=> @subscribeToFilePath(@getPath()))
        @handleEvents()
        @renderMarkdown()
      else
        @subscribeToFilePath(@filePath)

    if atom.workspace?
      resolve()
    else
      @disposables.add atom.packages.onDidActivateInitialPackages(resolve)

  editorForId: (editorId) ->
    for editor in atom.workspace.getTextEditors()
      return editor if editor.id?.toString() is editorId.toString()
    null

  handleEvents: ->
    @disposables.add atom.grammars.onDidAddGrammar => _.debounce((=> @renderMarkdown()), 250)
    @disposables.add atom.grammars.onDidUpdateGrammar _.debounce((=> @renderMarkdown()), 250)

    atom.commands.add @element,
      'core:move-up': =>
        @scrollUp()
      'core:move-down': =>
        @scrollDown()
      'core:save-as': (event) =>
        event.stopPropagation()
        @saveAs()
      'core:copy': (event) =>
        event.stopPropagation() if @copyToClipboard()
      'markdown-preview:zoom-in': =>
        zoomLevel = parseFloat(@css('zoom')) or 1
        @css('zoom', zoomLevel + .1)
      'markdown-preview:zoom-out': =>
        zoomLevel = parseFloat(@css('zoom')) or 1
        @css('zoom', zoomLevel - .1)
      'markdown-preview:reset-zoom': =>
        @css('zoom', 1)

    changeHandler = =>
      @renderMarkdown()

      pane = atom.workspace.paneForItem(this)
      if pane? and pane isnt atom.workspace.getActivePane()
        pane.activateItem(this)

    if @file?
      @disposables.add @file.onDidChange(changeHandler)
    else if @editor?
      @disposables.add @editor.getBuffer().onDidStopChanging ->
        changeHandler() if atom.config.get 'markdown-preview.liveUpdate'
      @disposables.add @editor.onDidChangePath => @emitter.emit 'did-change-title'
      @disposables.add @editor.getBuffer().onDidSave ->
        changeHandler() unless atom.config.get 'markdown-preview.liveUpdate'
      @disposables.add @editor.getBuffer().onDidReload ->
        changeHandler() unless atom.config.get 'markdown-preview.liveUpdate'

    @disposables.add atom.config.onDidChange 'markdown-preview.breakOnSingleNewline', changeHandler

    @disposables.add atom.config.observe 'markdown-preview.useGitHubStyle', (useGitHubStyle) =>
      if useGitHubStyle
        @element.setAttribute('data-use-github-style', '')
      else
        @element.removeAttribute('data-use-github-style')

  renderMarkdown: ->
    @showLoading() unless @loaded    
    if fontSize = atom.config.get('editor.fontSize')
      @element.style.cssText = 'font-size: ' + fontSize + 'px;'
    @getMarkdownSource()
    .then (source) => @renderMarkdownText(source) if source?
    .catch (reason) => @showError({message: reason})

  getMarkdownSource: ->
    if @file?.getPath()
      @file.read().then (source) =>
        if source is null
          Promise.reject("#{@file.getBaseName()} could not be found")
        else
          Promise.resolve(source)
      .catch (reason) -> Promise.reject(reason)
    else if @editor?
      Promise.resolve(@editor.getText())
    else
      Promise.reject()

  getHTML: (callback) ->
    @getMarkdownSource().then (source) =>
      return unless source?

      renderer.toHTML source, @getPath(), @getGrammar(), callback

  scrollToViewPosition: ->
    scrollPercentage = 0
    markerLine = -1
    correspondingElement = null
    for textEditor in atom.workspace.getTextEditors()
      if textEditor.id.toString() == @editorId
        markerLine = textEditor.cursors[0].marker.oldHeadBufferPosition.row;
        # Do a binary search for the right line
        left = 0
        right = @element.childNodes.length - 1
        while left <= right
          mid = Math.ceil((left + right) / 2)
          child = @element.childNodes[mid]
          validLeft = mid
          childLine = 0
          if typeof child.dataset == "undefined"
            validLeft = mid - 1
            while validLeft >= left and typeof @element.childNodes[validLeft].dataset == "undefined"
              validLeft -= 1
            validRight = mid + 1
            while validRight <= right and typeof @element.childNodes[validRight].dataset == "undefined"
              validRight += 1        
            a1 = parseInt(@element.childNodes[validLeft].dataset['line'])
            a2 = (@element.childNodes[validRight].dataset['line'] - @element.childNodes[validLeft].dataset['line']) / (validRight - validLeft)
            childLine = a1 + a2
          else
            childLine = parseInt(child.dataset['line'])
          if childLine == markerLine
            left = validLeft
            break
          else if childLine < markerLine
            left = mid + 1
          else
            right = mid - 1
        if left >= @element.childNodes.length
          left = @element.childNodes.length - 1        
        correspondingElement = @element.childNodes[left]
        while typeof correspondingElement.offsetTop == "undefined" and left >= 0
          left = left - 1
          correspondingElement = @element.childNodes[left]
        break
    if correspondingElement != null
      compensation = (textEditor.cursors[0].marker.oldHeadScreenPosition.row - textEditor.firstVisibleScreenRow) * textEditor.editorElement.model.lineHeightInPixels
      #console.log(correspondingElement.model.constructor.name )
      if typeof correspondingElement.model != "undefined" and correspondingElement.model.constructor.name == "TextEditor" and correspondingElement.model.cursors.length > 0
        compensation -= correspondingElement.model.cursors[0].marker.oldHeadBufferPosition.row * correspondingElement.model.lineHeightInPixels
      @element.scrollTop = correspondingElement.offsetTop - compensation

  renderMarkdownText: (text) ->
    renderer.toDOMFragment text, @getPath(), @getGrammar(), (error, domFragment) =>
      if error
        @showError(error)
      else
        @loading = false
        @loaded = true
        @element.textContent = ''
        @element.appendChild(domFragment)
        @scrollToViewPosition()
        @emitter.emit 'did-change-markdown'

  getTitle: ->
    if @file? and @getPath()?
      "#{path.basename(@getPath())} Preview"
    else if @editor?
      "#{@editor.getTitle()} Preview"
    else
      "Markdown Preview"

  getIconName: ->
    "markdown"

  getURI: ->
    if @file?
      "markdown-preview://#{@getPath()}"
    else
      "markdown-preview://editor/#{@editorId}"

  getPath: ->
    if @file?
      @file.getPath()
    else if @editor?
      @editor.getPath()

  getGrammar: ->
    @editor?.getGrammar()

  getDocumentStyleSheets: -> # This function exists so we can stub it
    document.styleSheets

  getTextEditorStyles: ->
    textEditorStyles = document.createElement("atom-styles")
    textEditorStyles.initialize(atom.styles)
    textEditorStyles.setAttribute "context", "atom-text-editor"
    document.body.appendChild textEditorStyles

    # Extract style elements content
    Array.prototype.slice.apply(textEditorStyles.childNodes).map (styleElement) ->
      styleElement.innerText

  getMarkdownPreviewCSS: ->
    markdownPreviewRules = []
    ruleRegExp = /\.markdown-preview/
    cssUrlRegExp = /url\(atom:\/\/markdown-preview\/assets\/(.*)\)/

    for stylesheet in @getDocumentStyleSheets()
      if stylesheet.rules?
        for rule in stylesheet.rules
          # We only need `.markdown-review` css
          markdownPreviewRules.push(rule.cssText) if rule.selectorText?.match(ruleRegExp)?

    markdownPreviewRules
      .concat(@getTextEditorStyles())
      .join('\n')
      .replace(/atom-text-editor/g, 'pre.editor-colors')
      .replace(/:host/g, '.host') # Remove shadow-dom :host selector causing problem on FF
      .replace cssUrlRegExp, (match, assetsName, offset, string) -> # base64 encode assets
        assetPath = path.join __dirname, '../assets', assetsName
        originalData = fs.readFileSync assetPath, 'binary'
        base64Data = new Buffer(originalData, 'binary').toString('base64')
        "url('data:image/jpeg;base64,#{base64Data}')"

  showError: (result) ->
    @element.textContent = ''
    h2 = document.createElement('h2')
    h2.textContent = 'Prevewing Markdown Failed'
    @element.appendChild(h2)
    if failureMessage = result?.message
      h3 = document.createElement('h3')
      h3.textContent = failureMessage
      @element.appendChild(h3)

  showLoading: ->
    @loading = true
    @element.textContent = ''
    div = document.createElement('div')
    div.classList.add('markdown-spinner')
    div.textContent = 'Loading Markdown\u2026'
    @element.appendChild(div)

  copyToClipboard: ->
    return false if @loading

    selection = window.getSelection()
    selectedText = selection.toString()
    selectedNode = selection.baseNode

    # Use default copy event handler if there is selected text inside this view
    return false if selectedText and selectedNode? and (@element is selectedNode or @element.contains(selectedNode))

    @getHTML (error, html) ->
      if error?
        console.warn('Copying Markdown as HTML failed', error)
      else
        atom.clipboard.write(html)

    true

  saveAs: ->
    return if @loading

    filePath = @getPath()
    title = 'Markdown to HTML'
    if filePath
      title = path.parse(filePath).name
      filePath += '.html'
    else
      filePath = 'untitled.md.html'
      if projectPath = atom.project.getPaths()[0]
        filePath = path.join(projectPath, filePath)

    if htmlFilePath = atom.showSaveDialogSync(filePath)

      @getHTML (error, htmlBody) =>
        if error?
          console.warn('Saving Markdown as HTML failed', error)
        else

          html = """
            <!DOCTYPE html>
            <html>
              <head>
                  <meta charset="utf-8" />
                  <title>#{title}</title>
                  <style>#{@getMarkdownPreviewCSS()}</style>
              </head>
              <body class='markdown-preview' data-use-github-style>#{htmlBody}</body>
            </html>""" + "\n" # Ensure trailing newline

          fs.writeFileSync(htmlFilePath, html)
          atom.workspace.open(htmlFilePath)
