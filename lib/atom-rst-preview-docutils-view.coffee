path = require 'path'

{Emitter, Disposable, CompositeDisposable, File} = require 'atom'
{$, $$$, ScrollView} = require 'atom-space-pen-views'
Grim = require 'grim'
_ = require 'underscore-plus'
fs = require 'fs-plus'

renderer = require './renderer'

module.exports =
class RestructeredTextPreviewView extends ScrollView
  @content: ->
    @div class: 'atom-rst-preview-docutils native-key-bindings', tabindex: -1

  constructor: ({@editorId, @filePath}) ->
    super
    @emitter = new Emitter
    @disposables = new CompositeDisposable
    @loaded = false

  attached: ->
    return if @isAttached
    @isAttached = true

    if @editorId?
      @resolveEditor(@editorId)
    else
      if atom.workspace?
        @subscribeToFilePath(@filePath)
      else
        @disposables.add atom.packages.onDidActivateInitialPackages =>
          @subscribeToFilePath(@filePath)

  serialize: ->
    deserializer: 'RestructeredTextPreviewView'
    filePath: @getPath() ? @filePath
    editorId: @editorId

  destroy: ->
    @disposables.dispose()

  onDidChangeTitle: (callback) ->
    @emitter.on 'did-change-title', callback

  onDidChangeModified: (callback) ->
    # No op to suppress deprecation warning
    new Disposable

  onDidChangeRst: (callback) ->
    @emitter.on 'did-change-rst', callback

  subscribeToFilePath: (filePath) ->
    @file = new File(filePath)
    @emitter.emit 'did-change-title'
    @disposables.add @file.onDidRename(=> @emitter.emit 'did-change-title')
    @handleEvents()
    @renderRst()

  resolveEditor: (editorId) ->
    resolve = =>
      @editor = @editorForId(editorId)

      if @editor?
        @emitter.emit 'did-change-title'
        @disposables.add @editor.onDidDestroy(=> @subscribeToFilePath(@getPath()))
        @handleEvents()
        @renderRst()
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
    @disposables.add atom.grammars.onDidAddGrammar => _.debounce((=> @renderRst()), 250)
    @disposables.add atom.grammars.onDidUpdateGrammar _.debounce((=> @renderRst()), 250)

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
      'atom-rst-preview-docutils:zoom-in': =>
        zoomLevel = parseFloat(@css('zoom')) or 1
        @css('zoom', zoomLevel + .1)
      'atom-rst-preview-docutils:zoom-out': =>
        zoomLevel = parseFloat(@css('zoom')) or 1
        @css('zoom', zoomLevel - .1)
      'atom-rst-preview-docutils:reset-zoom': =>
        @css('zoom', 1)

    changeHandler = =>
      @renderRst()

      # TODO: Remove paneForURI call when ::paneForItem is released
      pane = atom.workspace.paneForItem?(this) ? atom.workspace.paneForURI(@getURI())
      if pane? and pane isnt atom.workspace.getActivePane()
        pane.activateItem(this)

    if @file?
      @disposables.add @file.onDidChange(changeHandler)
    else if @editor?
      @disposables.add @editor.getBuffer().onDidStopChanging ->
        changeHandler() if atom.config.get 'atom-rst-preview-docutils.liveUpdate'
      @disposables.add @editor.onDidChangePath => @emitter.emit 'did-change-title'
      @disposables.add @editor.getBuffer().onDidSave ->
        changeHandler() unless atom.config.get 'atom-rst-preview-docutils.liveUpdate'
      @disposables.add @editor.getBuffer().onDidReload ->
        changeHandler() unless atom.config.get 'atom-rst-preview-docutils.liveUpdate'

  renderRst: ->
    @showLoading() unless @loaded
    @getRstSource()
    .then (source) => @renderRstText(source) if source?
    .catch (reason) => @showError({message: reason})

  getRstSource: ->
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
    @getRstSource().then (source) =>
      return unless source?

      renderer.toHTML source, @getPath(), @getGrammar(), callback

  renderRstText: (text) ->
    renderer.toDOMFragment text, @getPath(), @getGrammar(), (error, domFragment) =>
      if error
        @showError(error)
      else
        @loading = false
        @loaded = true
        @html(domFragment)
        @emitter.emit 'did-change-rst'
        @originalTrigger('atom-rst-preview-docutils:rst-changed')

  getTitle: ->
    if @file? and @getPath()?
      "#{path.basename(@getPath())} Preview"
    else if @editor?
      "#{@editor.getTitle()} Preview"
    else
      "RestructeredText Preview"

  getIconName: ->
    "rst"

  getURI: ->
    if @file?
      "atom-rst-preview-docutils://#{@getPath()}"
    else
      "atom-rst-preview-docutils://editor/#{@editorId}"

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

  getRstPreviewCSS: ->
    markdowPreviewRules = []
    ruleRegExp = /\.atom-rst-preview-docutils/
    cssUrlRefExp = /url\(atom:\/\/atom-rst-preview-docutils\/assets\/(.*)\)/

    for stylesheet in @getDocumentStyleSheets()
      if stylesheet.rules?
        for rule in stylesheet.rules
          # We only need `.rst-review` css
          markdowPreviewRules.push(rule.cssText) if rule.selectorText?.match(ruleRegExp)?

    markdowPreviewRules
      .concat(@getTextEditorStyles())
      .join('\n')
      .replace(/atom-text-editor/g, 'pre.editor-colors')
      .replace(/:host/g, '.host') # Remove shadow-dom :host selector causing problem on FF
      .replace cssUrlRefExp, (match, assetsName, offset, string) -> # base64 encode assets
        assetPath = path.join __dirname, '../assets', assetsName
        originalData = fs.readFileSync assetPath, 'binary'
        base64Data = new Buffer(originalData, 'binary').toString('base64')
        "url('data:image/jpeg;base64,#{base64Data}')"

  showError: (result) ->
    console.error(result)
    failureMessage = result?.message

    @html $$$ ->
      @h2 'Previewing RestructeredText Failed'
      @h3 failureMessage.toString() if failureMessage?
      @div result if !failureMessage and result?

  showLoading: ->
    @loading = true
    @html $$$ ->
      @div class: 'rst-spinner', 'Loading RestructeredText\u2026'

  copyToClipboard: ->
    return false if @loading

    selection = window.getSelection()
    selectedText = selection.toString()
    selectedNode = selection.baseNode

    # Use default copy event handler if there is selected text inside this view
    return false if selectedText and selectedNode? and (@[0] is selectedNode or $.contains(@[0], selectedNode))

    @getHTML (error, html) ->
      if error?
        console.warn('Copying RestructeredText as HTML failed', error)
      else
        atom.clipboard.write(html)

    true

  saveAs: ->
    return if @loading

    filePath = @getPath()
    title = 'RestructeredText to HTML'
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
          console.warn('Saving RestructeredText as HTML failed', error)
        else

          html = """
            <!DOCTYPE html>
            <html>
              <head>
                  <meta charset="utf-8" />
                  <title>#{title}</title>
                  <style>#{@getRstPreviewCSS()}</style>
              </head>
              <body class='atom-rst-preview-docutils'>#{htmlBody}</body>
            </html>""" + "\n" # Ensure trailing newline

          fs.writeFileSync(htmlFilePath, html)
          atom.workspace.open(htmlFilePath)

  isEqual: (other) ->
    @[0] is other?[0] # Compare DOM elements

if Grim.includeDeprecatedAPIs
  RestructeredTextPreviewView::on = (eventName) ->
    if eventName is 'atom-rst-preview-docutils:roaster-changed'
      Grim.deprecate("Use RestructeredTextPreviewView::onDidChangeRst instead of the 'atom-rst-preview-docutils:rst-changed' jQuery event")
    super
0
