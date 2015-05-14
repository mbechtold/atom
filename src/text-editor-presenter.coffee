{CompositeDisposable, Emitter} = require 'event-kit'
{Point, Range} = require 'text-buffer'
_ = require 'underscore-plus'
Decoration = require './decoration'

module.exports =
class TextEditorPresenter
  toggleCursorBlinkHandle: null
  startBlinkingCursorsAfterDelay: null
  stoppedScrollingTimeoutId: null
  mouseWheelScreenRow: null
  scopedCharacterWidthsChangeCount: 0
  overlayDimensions: {}

  constructor: (params) ->
    {@model, @autoHeight, @explicitHeight, @contentFrameWidth, @scrollTop, @scrollLeft, @boundingClientRect, @windowWidth, @windowHeight, @gutterWidth} = params
    {horizontalScrollbarHeight, verticalScrollbarWidth} = params
    {@lineHeight, @baseCharacterWidth, @lineOverdrawMargin, @backgroundColor, @gutterBackgroundColor} = params
    {@cursorBlinkPeriod, @cursorBlinkResumeDelay, @stoppedScrollingDelay, @focused} = params
    @measuredHorizontalScrollbarHeight = horizontalScrollbarHeight
    @measuredVerticalScrollbarWidth = verticalScrollbarWidth
    @gutterWidth ?= 0

    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @characterWidthsByScope = {}
    @transferMeasurementsToModel()
    @observeModel()
    @observeConfig()
    @buildState()
    @startBlinkingCursors() if @focused
    @updating = false

  destroy: ->
    @disposables.dispose()

  # Calls your `callback` when some changes in the model occurred and the current state has been updated.
  onDidUpdateState: (callback) ->
    @emitter.on 'did-update-state', callback

  emitDidUpdateState: ->
    @emitter.emit "did-update-state" if @isBatching()

  transferMeasurementsToModel: ->
    @model.setHeight(@explicitHeight) if @explicitHeight?
    @model.setWidth(@contentFrameWidth) if @contentFrameWidth?
    @model.setLineHeightInPixels(@lineHeight) if @lineHeight?
    @model.setDefaultCharWidth(@baseCharacterWidth) if @baseCharacterWidth?
    @model.setScrollTop(@scrollTop) if @scrollTop?
    @model.setScrollLeft(@scrollLeft) if @scrollLeft?
    @model.setVerticalScrollbarWidth(@measuredVerticalScrollbarWidth) if @measuredVerticalScrollbarWidth?
    @model.setHorizontalScrollbarHeight(@measuredHorizontalScrollbarHeight) if @measuredHorizontalScrollbarHeight?

  # Private: Determines whether {TextEditorPresenter} is currently batching changes.
  # Returns a {Boolean}, `true` if is collecting changes, `false` if is applying them.
  isBatching: ->
    @updating is false

  # Public: Gets this presenter's state, updating it just in time before returning from this function.
  # Returns a state {Object}, useful for rendering to screen.
  getState: ->
    @updating = true

    @updateContentDimensions()
    @updateScrollbarDimensions()
    @updateStartRow()
    @updateEndRow()

    @updateFocusedState() if @shouldUpdateFocusedState
    @updateHeightState() if @shouldUpdateHeightState
    @updateVerticalScrollState() if @shouldUpdateVerticalScrollState
    @updateHorizontalScrollState() if @shouldUpdateHorizontalScrollState
    @updateScrollbarsState() if @shouldUpdateScrollbarsState
    @updateHiddenInputState() if @shouldUpdateHiddenInputState
    @updateContentState() if @shouldUpdateContentState
    @updateDecorations() if @shouldUpdateDecorations
    @updateLinesState() if @shouldUpdateLinesState
    @updateCursorsState() if @shouldUpdateCursorsState
    @updateOverlaysState() if @shouldUpdateOverlaysState
    @updateLineNumberGutterState() if @shouldUpdateLineNumberGutterState
    @updateLineNumbersState() if @shouldUpdateLineNumbersState
    @updateGutterOrderState() if @shouldUpdateGutterOrderState
    @updateCustomGutterDecorationState() if @shouldUpdateCustomGutterDecorationState
    @updating = false

    @resetTrackedUpdates()

    @state

  resetTrackedUpdates: ->
    @shouldUpdateFocusedState = false
    @shouldUpdateHeightState = false
    @shouldUpdateVerticalScrollState = false
    @shouldUpdateHorizontalScrollState = false
    @shouldUpdateScrollbarsState = false
    @shouldUpdateHiddenInputState = false
    @shouldUpdateContentState = false
    @shouldUpdateDecorations = false
    @shouldUpdateLinesState = false
    @shouldUpdateCursorsState = false
    @shouldUpdateOverlaysState = false
    @shouldUpdateLineNumberGutterState = false
    @shouldUpdateLineNumbersState = false
    @shouldUpdateGutterOrderState = false
    @shouldUpdateCustomGutterDecorationState = false

  observeModel: ->
    @disposables.add @model.onDidChange =>
      @updateContentDimensions()
      @updateEndRow()
      @shouldUpdateHeightState = true
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateScrollbarsState = true
      @shouldUpdateContentState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateLineNumberGutterState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateGutterOrderState = true
      @shouldUpdateCustomGutterDecorationState = true

      @emitDidUpdateState()
    @disposables.add @model.onDidChangeGrammar(@didChangeGrammar.bind(this))
    @disposables.add @model.onDidChangePlaceholderText =>
      @shouldUpdateContentState = true

      @emitDidUpdateState()
    @disposables.add @model.onDidChangeMini =>
      @shouldUpdateScrollbarsState = true
      @shouldUpdateContentState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateLineNumberGutterState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateGutterOrderState = true
      @shouldUpdateCustomGutterDecorationState = true
      @updateScrollbarDimensions()
      @updateCommonGutterState()

      @emitDidUpdateState()
    @disposables.add @model.onDidChangeLineNumberGutterVisible =>
      @shouldUpdateLineNumberGutterState = true
      @shouldUpdateGutterOrderState = true
      @updateCommonGutterState()

      @emitDidUpdateState()
    @disposables.add @model.onDidAddDecoration(@didAddDecoration.bind(this))
    @disposables.add @model.onDidAddCursor(@didAddCursor.bind(this))
    @disposables.add @model.onDidChangeScrollTop(@setScrollTop.bind(this))
    @disposables.add @model.onDidChangeScrollLeft(@setScrollLeft.bind(this))
    @observeDecoration(decoration) for decoration in @model.getDecorations()
    @observeCursor(cursor) for cursor in @model.getCursors()
    @disposables.add @model.onDidAddGutter(@didAddGutter.bind(this))
    return

  observeConfig: ->
    configParams = {scope: @model.getRootScopeDescriptor()}

    @scrollPastEnd = atom.config.get('editor.scrollPastEnd', configParams)
    @showLineNumbers = atom.config.get('editor.showLineNumbers', configParams)
    @showIndentGuide = atom.config.get('editor.showIndentGuide', configParams)

    if @configDisposables?
      @configDisposables?.dispose()
      @disposables.remove(@configDisposables)

    @configDisposables = new CompositeDisposable
    @disposables.add(@configDisposables)

    @configDisposables.add atom.config.onDidChange 'editor.showIndentGuide', configParams, ({newValue}) =>
      @showIndentGuide = newValue
      @shouldUpdateContentState = true

      @emitDidUpdateState()
    @configDisposables.add atom.config.onDidChange 'editor.scrollPastEnd', configParams, ({newValue}) =>
      @scrollPastEnd = newValue
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateScrollbarsState = true
      @updateScrollHeight()

      @emitDidUpdateState()
    @configDisposables.add atom.config.onDidChange 'editor.showLineNumbers', configParams, ({newValue}) =>
      @showLineNumbers = newValue
      @shouldUpdateLineNumberGutterState = true
      @shouldUpdateGutterOrderState = true
      @updateCommonGutterState()

      @emitDidUpdateState()

  didChangeGrammar: ->
    @observeConfig()
    @shouldUpdateContentState = true
    @shouldUpdateLineNumberGutterState = true
    @shouldUpdateGutterOrderState = true
    @updateCommonGutterState()

    @emitDidUpdateState()

  buildState: ->
    @state =
      horizontalScrollbar: {}
      verticalScrollbar: {}
      hiddenInput: {}
      content:
        scrollingVertically: false
        cursorsVisible: false
        lines: {}
        highlights: {}
        overlays: {}
      gutters: []
    # Shared state that is copied into ``@state.gutters`.
    @sharedGutterStyles = {}
    @customGutterDecorations = {}
    @lineNumberGutter =
      lineNumbers: {}

    @updateState()

  updateState: ->
    @updateContentDimensions()
    @updateScrollbarDimensions()
    @updateStartRow()
    @updateEndRow()

    @updateFocusedState()
    @updateHeightState()
    @updateVerticalScrollState()
    @updateHorizontalScrollState()
    @updateScrollbarsState()
    @updateHiddenInputState()
    @updateContentState()
    @updateDecorations()
    @updateLinesState()
    @updateCursorsState()
    @updateOverlaysState()
    @updateLineNumberGutterState()
    @updateLineNumbersState()
    @updateCommonGutterState()
    @updateGutterOrderState()
    @updateCustomGutterDecorationState()

    @resetTrackedUpdates()

  updateFocusedState: ->
    @state.focused = @focused

  updateHeightState: ->
    if @autoHeight
      @state.height = @contentHeight
    else
      @state.height = null

  updateVerticalScrollState: ->
    @state.content.scrollHeight = @scrollHeight
    @sharedGutterStyles.scrollHeight = @scrollHeight
    @state.verticalScrollbar.scrollHeight = @scrollHeight

    @state.content.scrollTop = @scrollTop
    @sharedGutterStyles.scrollTop = @scrollTop
    @state.verticalScrollbar.scrollTop = @scrollTop

  updateHorizontalScrollState: ->
    @state.content.scrollWidth = @scrollWidth
    @state.horizontalScrollbar.scrollWidth = @scrollWidth

    @state.content.scrollLeft = @scrollLeft
    @state.horizontalScrollbar.scrollLeft = @scrollLeft

  updateScrollbarsState: ->
    @state.horizontalScrollbar.visible = @horizontalScrollbarHeight > 0
    @state.horizontalScrollbar.height = @measuredHorizontalScrollbarHeight
    @state.horizontalScrollbar.right = @verticalScrollbarWidth

    @state.verticalScrollbar.visible = @verticalScrollbarWidth > 0
    @state.verticalScrollbar.width = @measuredVerticalScrollbarWidth
    @state.verticalScrollbar.bottom = @horizontalScrollbarHeight

  updateHiddenInputState: ->
    return unless lastCursor = @model.getLastCursor()

    {top, left, height, width} = @pixelRectForScreenRange(lastCursor.getScreenRange())

    if @focused
      top -= @scrollTop
      left -= @scrollLeft
      @state.hiddenInput.top = Math.max(Math.min(top, @clientHeight - height), 0)
      @state.hiddenInput.left = Math.max(Math.min(left, @clientWidth - width), 0)
    else
      @state.hiddenInput.top = 0
      @state.hiddenInput.left = 0

    @state.hiddenInput.height = height
    @state.hiddenInput.width = Math.max(width, 2)

  updateContentState: ->
    @state.content.scrollWidth = @scrollWidth
    @state.content.scrollLeft = @scrollLeft
    @state.content.indentGuidesVisible = not @model.isMini() and @showIndentGuide
    @state.content.backgroundColor = if @model.isMini() then null else @backgroundColor
    @state.content.placeholderText = if @model.isEmpty() then @model.getPlaceholderText() else null

  updateLinesState: ->
    return unless @startRow? and @endRow? and @lineHeight?

    visibleLineIds = {}
    row = @startRow
    while row < @endRow
      line = @model.tokenizedLineForScreenRow(row)
      unless line?
        throw new Error("No line exists for row #{row}. Last screen row: #{@model.getLastScreenRow()}")

      visibleLineIds[line.id] = true
      if @state.content.lines.hasOwnProperty(line.id)
        @updateLineState(row, line)
      else
        @buildLineState(row, line)
      row++

    if @mouseWheelScreenRow?
      if preservedLine = @model.tokenizedLineForScreenRow(@mouseWheelScreenRow)
        visibleLineIds[preservedLine.id] = true

    for id, line of @state.content.lines
      unless visibleLineIds.hasOwnProperty(id)
        delete @state.content.lines[id]
    return

  updateLineState: (row, line) ->
    lineState = @state.content.lines[line.id]
    lineState.screenRow = row
    lineState.top = row * @lineHeight
    lineState.decorationClasses = @lineDecorationClassesForRow(row)

  buildLineState: (row, line) ->
    @state.content.lines[line.id] =
      screenRow: row
      text: line.text
      tokens: line.tokens
      isOnlyWhitespace: line.isOnlyWhitespace()
      endOfLineInvisibles: line.endOfLineInvisibles
      indentLevel: line.indentLevel
      tabLength: line.tabLength
      fold: line.fold
      top: row * @lineHeight
      decorationClasses: @lineDecorationClassesForRow(row)

  updateCursorsState: ->
    @state.content.cursors = {}
    @updateCursorState(cursor) for cursor in @model.cursors # using property directly to avoid allocation
    return

  updateCursorState: (cursor, destroyOnly = false) ->
    delete @state.content.cursors[cursor.id]

    return if destroyOnly
    return unless @startRow? and @endRow? and @hasPixelRectRequirements() and @baseCharacterWidth?
    return unless cursor.isVisible() and @startRow <= cursor.getScreenRow() < @endRow

    pixelRect = @pixelRectForScreenRange(cursor.getScreenRange())
    pixelRect.width = @baseCharacterWidth if pixelRect.width is 0
    @state.content.cursors[cursor.id] = pixelRect

    @emitDidUpdateState()

  updateOverlaysState: ->
    return unless @hasOverlayPositionRequirements()

    visibleDecorationIds = {}

    for decoration in @model.getOverlayDecorations()
      continue unless decoration.getMarker().isValid()

      {item, position} = decoration.getProperties()
      if position is 'tail'
        screenPosition = decoration.getMarker().getTailScreenPosition()
      else
        screenPosition = decoration.getMarker().getHeadScreenPosition()

      pixelPosition = @pixelPositionForScreenPosition(screenPosition)

      {scrollTop, scrollLeft} = @state.content

      top = pixelPosition.top + @lineHeight - scrollTop
      left = pixelPosition.left + @gutterWidth - scrollLeft

      if overlayDimensions = @overlayDimensions[decoration.id]
        {itemWidth, itemHeight, contentMargin} = overlayDimensions

        rightDiff = left + @boundingClientRect.left + itemWidth + contentMargin - @windowWidth
        left -= rightDiff if rightDiff > 0

        leftDiff = left + @boundingClientRect.left + contentMargin
        left -= leftDiff if leftDiff < 0

        if top + @boundingClientRect.top + itemHeight > @windowHeight and top - (itemHeight + @lineHeight) >= 0
          top -= itemHeight + @lineHeight

      pixelPosition.top = top
      pixelPosition.left = left

      @state.content.overlays[decoration.id] ?= {item}
      @state.content.overlays[decoration.id].pixelPosition = pixelPosition
      visibleDecorationIds[decoration.id] = true

    for id of @state.content.overlays
      delete @state.content.overlays[id] unless visibleDecorationIds[id]

    for id of @overlayDimensions
      delete @overlayDimensions[id] unless visibleDecorationIds[id]

    return

  updateLineNumberGutterState: ->
    @lineNumberGutter.maxLineNumberDigits = @model.getLineCount().toString().length

  updateCommonGutterState: ->
    @sharedGutterStyles.backgroundColor = if @gutterBackgroundColor isnt "rgba(0, 0, 0, 0)"
      @gutterBackgroundColor
    else
      @backgroundColor

  didAddGutter: (gutter) ->
    gutterDisposables = new CompositeDisposable
    gutterDisposables.add gutter.onDidChangeVisible =>
      @shouldUpdateGutterOrderState = true
      @shouldUpdateCustomGutterDecorationState = true

      @emitDidUpdateState()
    gutterDisposables.add gutter.onDidDestroy =>
      @disposables.remove(gutterDisposables)
      gutterDisposables.dispose()
      @shouldUpdateGutterOrderState = true

      @emitDidUpdateState()
      # It is not necessary to @updateCustomGutterDecorationState here.
      # The destroyed gutter will be removed from the list of gutters in @state,
      # and thus will be removed from the DOM.
    @disposables.add(gutterDisposables)
    @shouldUpdateGutterOrderState = true
    @shouldUpdateCustomGutterDecorationState = true

    @emitDidUpdateState()

  updateGutterOrderState: ->
    @state.gutters = []
    if @model.isMini()
      return
    for gutter in @model.getGutters()
      isVisible = @gutterIsVisible(gutter)
      if gutter.name is 'line-number'
        content = @lineNumberGutter
      else
        @customGutterDecorations[gutter.name] ?= {}
        content = @customGutterDecorations[gutter.name]
      @state.gutters.push({
        gutter,
        visible: isVisible,
        styles: @sharedGutterStyles,
        content,
      })

  # Updates the decoration state for the gutter with the given gutterName.
  # @customGutterDecorations is an {Object}, with the form:
  #   * gutterName : {
  #     decoration.id : {
  #       top: # of pixels from top
  #       height: # of pixels height of this decoration
  #       item (optional): HTMLElement or space-pen View
  #       class (optional): {String} class
  #     }
  #   }
  updateCustomGutterDecorationState: ->
    return unless @startRow? and @endRow? and @lineHeight?

    if @model.isMini()
      # Mini editors have no gutter decorations.
      # We clear instead of reassigning to preserve the reference.
      @clearAllCustomGutterDecorations()

    for gutter in @model.getGutters()
      gutterName = gutter.name
      gutterDecorations = @customGutterDecorations[gutterName]
      if gutterDecorations
        # Clear the gutter decorations; they are rebuilt.
        # We clear instead of reassigning to preserve the reference.
        @clearDecorationsForCustomGutterName(gutterName)
      else
        @customGutterDecorations[gutterName] = {}
      return if not @gutterIsVisible(gutter)

      relevantDecorations = @customGutterDecorationsInRange(gutterName, @startRow, @endRow - 1)
      relevantDecorations.forEach (decoration) =>
        decorationRange = decoration.getMarker().getScreenRange()
        @customGutterDecorations[gutterName][decoration.id] =
          top: @lineHeight * decorationRange.start.row
          height: @lineHeight * decorationRange.getRowCount()
          item: decoration.getProperties().item
          class: decoration.getProperties().class

  clearAllCustomGutterDecorations: ->
    allGutterNames = Object.keys(@customGutterDecorations)
    for gutterName in allGutterNames
      @clearDecorationsForCustomGutterName(gutterName)

  clearDecorationsForCustomGutterName: (gutterName) ->
    gutterDecorations = @customGutterDecorations[gutterName]
    if gutterDecorations
      allDecorationIds = Object.keys(gutterDecorations)
      for decorationId in allDecorationIds
        delete gutterDecorations[decorationId]

  gutterIsVisible: (gutterModel) ->
    isVisible = gutterModel.isVisible()
    if gutterModel.name is 'line-number'
      isVisible = isVisible and @showLineNumbers
    isVisible

  updateLineNumbersState: ->
    return unless @startRow? and @endRow? and @lineHeight?

    visibleLineNumberIds = {}

    if @startRow > 0
      rowBeforeStartRow = @startRow - 1
      lastBufferRow = @model.bufferRowForScreenRow(rowBeforeStartRow)
      wrapCount = rowBeforeStartRow - @model.screenRowForBufferRow(lastBufferRow)
    else
      lastBufferRow = null
      wrapCount = 0

    if @endRow > @startRow
      for bufferRow, i in @model.bufferRowsForScreenRows(@startRow, @endRow - 1)
        if bufferRow is lastBufferRow
          wrapCount++
          id = bufferRow + '-' + wrapCount
          softWrapped = true
        else
          id = bufferRow
          wrapCount = 0
          lastBufferRow = bufferRow
          softWrapped = false

        screenRow = @startRow + i
        top = screenRow * @lineHeight
        decorationClasses = @lineNumberDecorationClassesForRow(screenRow)
        foldable = @model.isFoldableAtScreenRow(screenRow)

        @lineNumberGutter.lineNumbers[id] = {screenRow, bufferRow, softWrapped, top, decorationClasses, foldable}
        visibleLineNumberIds[id] = true

    if @mouseWheelScreenRow?
      bufferRow = @model.bufferRowForScreenRow(@mouseWheelScreenRow)
      wrapCount = @mouseWheelScreenRow - @model.screenRowForBufferRow(bufferRow)
      id = bufferRow
      id += '-' + wrapCount if wrapCount > 0
      visibleLineNumberIds[id] = true

    for id of @lineNumberGutter.lineNumbers
      delete @lineNumberGutter.lineNumbers[id] unless visibleLineNumberIds[id]

    return

  updateStartRow: ->
    return unless @scrollTop? and @lineHeight?

    startRow = Math.floor(@scrollTop / @lineHeight) - @lineOverdrawMargin
    @startRow = Math.max(0, startRow)

  updateEndRow: ->
    return unless @scrollTop? and @lineHeight? and @height?

    startRow = Math.max(0, Math.floor(@scrollTop / @lineHeight))
    visibleLinesCount = Math.ceil(@height / @lineHeight) + 1
    endRow = startRow + visibleLinesCount + @lineOverdrawMargin
    @endRow = Math.min(@model.getScreenLineCount(), endRow)

  updateScrollWidth: ->
    return unless @contentWidth? and @clientWidth?

    scrollWidth = Math.max(@contentWidth, @clientWidth)
    unless @scrollWidth is scrollWidth
      @scrollWidth = scrollWidth
      @updateScrollLeft()

  updateScrollHeight: ->
    return unless @contentHeight? and @clientHeight?

    contentHeight = @contentHeight
    if @scrollPastEnd
      extraScrollHeight = @clientHeight - (@lineHeight * 3)
      contentHeight += extraScrollHeight if extraScrollHeight > 0
    scrollHeight = Math.max(contentHeight, @height)

    unless @scrollHeight is scrollHeight
      @scrollHeight = scrollHeight
      @updateScrollTop()

  updateContentDimensions: ->
    if @lineHeight?
      oldContentHeight = @contentHeight
      @contentHeight = @lineHeight * @model.getScreenLineCount()

    if @baseCharacterWidth?
      oldContentWidth = @contentWidth
      clip = @model.tokenizedLineForScreenRow(@model.getLongestScreenRow())?.isSoftWrapped()
      @contentWidth = @pixelPositionForScreenPosition([@model.getLongestScreenRow(), @model.getMaxScreenLineLength()], clip).left
      @contentWidth += 1 unless @model.isSoftWrapped() # account for cursor width

    if @contentHeight isnt oldContentHeight
      @updateHeight()
      @updateScrollbarDimensions()
      @updateScrollHeight()

    if @contentWidth isnt oldContentWidth
      @updateScrollbarDimensions()
      @updateScrollWidth()

  updateClientHeight: ->
    return unless @height? and @horizontalScrollbarHeight?

    clientHeight = @height - @horizontalScrollbarHeight
    unless @clientHeight is clientHeight
      @clientHeight = clientHeight
      @updateScrollHeight()
      @updateScrollTop()

  updateClientWidth: ->
    return unless @contentFrameWidth? and @verticalScrollbarWidth?

    clientWidth = @contentFrameWidth - @verticalScrollbarWidth
    unless @clientWidth is clientWidth
      @clientWidth = clientWidth
      @updateScrollWidth()
      @updateScrollLeft()

  updateScrollTop: ->
    scrollTop = @constrainScrollTop(@scrollTop)
    unless @scrollTop is scrollTop
      @scrollTop = scrollTop
      @updateStartRow()
      @updateEndRow()

  constrainScrollTop: (scrollTop) ->
    return scrollTop unless scrollTop? and @scrollHeight? and @clientHeight?
    Math.max(0, Math.min(scrollTop, @scrollHeight - @clientHeight))

  updateScrollLeft: ->
    @scrollLeft = @constrainScrollLeft(@scrollLeft)

  constrainScrollLeft: (scrollLeft) ->
    return scrollLeft unless scrollLeft? and @scrollWidth? and @clientWidth?
    Math.max(0, Math.min(scrollLeft, @scrollWidth - @clientWidth))

  updateScrollbarDimensions: ->
    return unless @contentFrameWidth? and @height?
    return unless @measuredVerticalScrollbarWidth? and @measuredHorizontalScrollbarHeight?
    return unless @contentWidth? and @contentHeight?

    clientWidthWithoutVerticalScrollbar = @contentFrameWidth
    clientWidthWithVerticalScrollbar = clientWidthWithoutVerticalScrollbar - @measuredVerticalScrollbarWidth
    clientHeightWithoutHorizontalScrollbar = @height
    clientHeightWithHorizontalScrollbar = clientHeightWithoutHorizontalScrollbar - @measuredHorizontalScrollbarHeight

    horizontalScrollbarVisible =
      not @model.isMini() and
        (@contentWidth > clientWidthWithoutVerticalScrollbar or
         @contentWidth > clientWidthWithVerticalScrollbar and @contentHeight > clientHeightWithoutHorizontalScrollbar)

    verticalScrollbarVisible =
      not @model.isMini() and
        (@contentHeight > clientHeightWithoutHorizontalScrollbar or
         @contentHeight > clientHeightWithHorizontalScrollbar and @contentWidth > clientWidthWithoutVerticalScrollbar)

    horizontalScrollbarHeight =
      if horizontalScrollbarVisible
        @measuredHorizontalScrollbarHeight
      else
        0

    verticalScrollbarWidth =
      if verticalScrollbarVisible
        @measuredVerticalScrollbarWidth
      else
        0

    unless @horizontalScrollbarHeight is horizontalScrollbarHeight
      @horizontalScrollbarHeight = horizontalScrollbarHeight
      @updateClientHeight()

    unless @verticalScrollbarWidth is verticalScrollbarWidth
      @verticalScrollbarWidth = verticalScrollbarWidth
      @updateClientWidth()

  lineDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, decoration of @lineDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(decoration.getProperties().class)
    decorationClasses

  lineNumberDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, decoration of @lineNumberDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(decoration.getProperties().class)
    decorationClasses

  # Returns a {Set} of {Decoration}s on the given custom gutter from startRow to endRow (inclusive).
  customGutterDecorationsInRange: (gutterName, startRow, endRow) ->
    decorations = new Set

    return decorations if @model.isMini() or gutterName is 'line-number' or
      not @customGutterDecorationsByGutterNameAndScreenRow[gutterName]

    for screenRow in [@startRow..@endRow - 1]
      for id, decoration of @customGutterDecorationsByGutterNameAndScreenRow[gutterName][screenRow]
        decorations.add(decoration)
    decorations

  getCursorBlinkPeriod: -> @cursorBlinkPeriod

  getCursorBlinkResumeDelay: -> @cursorBlinkResumeDelay

  setFocused: (focused) ->
    unless @focused is focused
      @focused = focused
      if @focused
        @startBlinkingCursors()
      else
        @stopBlinkingCursors(false)
      @shouldUpdateFocusedState = true
      @shouldUpdateHiddenInputState = true

      @emitDidUpdateState()

  setScrollTop: (scrollTop) ->
    scrollTop = @constrainScrollTop(scrollTop)

    unless @scrollTop is scrollTop or Number.isNaN(scrollTop)
      @scrollTop = scrollTop
      @model.setScrollTop(scrollTop)
      @updateStartRow()
      @updateEndRow()
      @didStartScrolling()
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateHiddenInputState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateCursorsState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateCustomGutterDecorationState = true
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  getScrollTop: ->
    @scrollTop

  didStartScrolling: ->
    if @stoppedScrollingTimeoutId?
      clearTimeout(@stoppedScrollingTimeoutId)
      @stoppedScrollingTimeoutId = null
    @stoppedScrollingTimeoutId = setTimeout(@didStopScrolling.bind(this), @stoppedScrollingDelay)
    @state.content.scrollingVertically = true
    @emitDidUpdateState()

  didStopScrolling: ->
    @state.content.scrollingVertically = false
    if @mouseWheelScreenRow?
      @mouseWheelScreenRow = null
      @shouldUpdateLinesState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateCustomGutterDecorationState = true

    @emitDidUpdateState()

  setScrollLeft: (scrollLeft) ->
    scrollLeft = @constrainScrollLeft(scrollLeft)
    unless @scrollLeft is scrollLeft or Number.isNaN(scrollLeft)
      oldScrollLeft = @scrollLeft
      @scrollLeft = scrollLeft
      @model.setScrollLeft(scrollLeft)
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateHiddenInputState = true
      @shouldUpdateCursorsState = true unless oldScrollLeft?
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  getScrollLeft: ->
    @scrollLeft

  setHorizontalScrollbarHeight: (horizontalScrollbarHeight) ->
    unless @measuredHorizontalScrollbarHeight is horizontalScrollbarHeight
      oldHorizontalScrollbarHeight = @measuredHorizontalScrollbarHeight
      @measuredHorizontalScrollbarHeight = horizontalScrollbarHeight
      @model.setHorizontalScrollbarHeight(horizontalScrollbarHeight)
      @updateScrollbarDimensions()
      @shouldUpdateScrollbarsState = true
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateCursorsState = true unless oldHorizontalScrollbarHeight?

      @emitDidUpdateState()

  setVerticalScrollbarWidth: (verticalScrollbarWidth) ->
    unless @measuredVerticalScrollbarWidth is verticalScrollbarWidth
      oldVerticalScrollbarWidth = @measuredVerticalScrollbarWidth
      @measuredVerticalScrollbarWidth = verticalScrollbarWidth
      @model.setVerticalScrollbarWidth(verticalScrollbarWidth)
      @updateScrollbarDimensions()
      @shouldUpdateScrollbarsState = true
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateCursorsState = true unless oldVerticalScrollbarWidth?

      @emitDidUpdateState()

  setAutoHeight: (autoHeight) ->
    unless @autoHeight is autoHeight
      @autoHeight = autoHeight
      @shouldUpdateHeightState = true

      @emitDidUpdateState()

  setExplicitHeight: (explicitHeight) ->
    unless @explicitHeight is explicitHeight
      @explicitHeight = explicitHeight
      @model.setHeight(explicitHeight)
      @updateHeight()
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateScrollbarsState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateCursorsState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateCustomGutterDecorationState = true

      @emitDidUpdateState()

  updateHeight: ->
    height = @explicitHeight ? @contentHeight
    unless @height is height
      @height = height
      @updateScrollbarDimensions()
      @updateClientHeight()
      @updateScrollHeight()
      @updateEndRow()

  setContentFrameWidth: (contentFrameWidth) ->
    unless @contentFrameWidth is contentFrameWidth
      oldContentFrameWidth = @contentFrameWidth
      @contentFrameWidth = contentFrameWidth
      @model.setWidth(contentFrameWidth)
      @updateScrollbarDimensions()
      @updateClientWidth()
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateScrollbarsState = true
      @shouldUpdateContentState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateCursorsState = true unless oldContentFrameWidth?

      @emitDidUpdateState()

  setBoundingClientRect: (boundingClientRect) ->
    unless @clientRectsEqual(@boundingClientRect, boundingClientRect)
      @boundingClientRect = boundingClientRect
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  clientRectsEqual: (clientRectA, clientRectB) ->
    clientRectA? and clientRectB? and
      clientRectA.top is clientRectB.top and
      clientRectA.left is clientRectB.left and
      clientRectA.width is clientRectB.width and
      clientRectA.height is clientRectB.height

  setWindowSize: (width, height) ->
    if @windowWidth isnt width or @windowHeight isnt height
      @windowWidth = width
      @windowHeight = height
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  setBackgroundColor: (backgroundColor) ->
    unless @backgroundColor is backgroundColor
      @backgroundColor = backgroundColor
      @shouldUpdateContentState = true
      @shouldUpdateLineNumberGutterState = true
      @updateCommonGutterState()
      @shouldUpdateGutterOrderState = true

      @emitDidUpdateState()

  setGutterBackgroundColor: (gutterBackgroundColor) ->
    unless @gutterBackgroundColor is gutterBackgroundColor
      @gutterBackgroundColor = gutterBackgroundColor
      @shouldUpdateLineNumberGutterState = true
      @updateCommonGutterState()
      @shouldUpdateGutterOrderState = true

      @emitDidUpdateState()

  setGutterWidth: (gutterWidth) ->
    if @gutterWidth isnt gutterWidth
      @gutterWidth = gutterWidth
      @updateOverlaysState()

  setLineHeight: (lineHeight) ->
    unless @lineHeight is lineHeight
      @lineHeight = lineHeight
      @model.setLineHeightInPixels(lineHeight)
      @updateContentDimensions()
      @updateScrollHeight()
      @updateHeight()
      @updateStartRow()
      @updateEndRow()
      @shouldUpdateHeightState = true
      @shouldUpdateHorizontalScrollState = true
      @shouldUpdateVerticalScrollState = true
      @shouldUpdateScrollbarsState = true
      @shouldUpdateHiddenInputState = true
      @shouldUpdateDecorations = true
      @shouldUpdateLinesState = true
      @shouldUpdateCursorsState = true
      @shouldUpdateLineNumbersState = true
      @shouldUpdateCustomGutterDecorationState = true
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  setMouseWheelScreenRow: (mouseWheelScreenRow) ->
    unless @mouseWheelScreenRow is mouseWheelScreenRow
      @mouseWheelScreenRow = mouseWheelScreenRow
      @didStartScrolling()

  setBaseCharacterWidth: (baseCharacterWidth) ->
    unless @baseCharacterWidth is baseCharacterWidth
      @baseCharacterWidth = baseCharacterWidth
      @model.setDefaultCharWidth(baseCharacterWidth)
      @characterWidthsChanged()

  getScopedCharacterWidth: (scopeNames, char) ->
    @getScopedCharacterWidths(scopeNames)[char]

  getScopedCharacterWidths: (scopeNames) ->
    scope = @characterWidthsByScope
    for scopeName in scopeNames
      scope[scopeName] ?= {}
      scope = scope[scopeName]
    scope.characterWidths ?= {}
    scope.characterWidths

  batchCharacterMeasurement: (fn) ->
    oldChangeCount = @scopedCharacterWidthsChangeCount
    @batchingCharacterMeasurement = true
    @model.batchCharacterMeasurement(fn)
    @batchingCharacterMeasurement = false
    @characterWidthsChanged() if oldChangeCount isnt @scopedCharacterWidthsChangeCount

  setScopedCharacterWidth: (scopeNames, character, width) ->
    @getScopedCharacterWidths(scopeNames)[character] = width
    @model.setScopedCharWidth(scopeNames, character, width)
    @scopedCharacterWidthsChangeCount++
    @characterWidthsChanged() unless @batchingCharacterMeasurement

  characterWidthsChanged: ->
    @updateContentDimensions()

    @shouldUpdateHorizontalScrollState = true
    @shouldUpdateVerticalScrollState = true
    @shouldUpdateScrollbarsState = true
    @shouldUpdateHiddenInputState = true
    @shouldUpdateContentState = true
    @shouldUpdateDecorations = true
    @shouldUpdateLinesState = true
    @shouldUpdateCursorsState = true
    @shouldUpdateOverlaysState = true

    @emitDidUpdateState()

  clearScopedCharacterWidths: ->
    @characterWidthsByScope = {}
    @model.clearScopedCharWidths()

  hasPixelPositionRequirements: ->
    @lineHeight? and @baseCharacterWidth?

  pixelPositionForScreenPosition: (screenPosition, clip=true) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = @model.clipScreenPosition(screenPosition) if clip

    targetRow = screenPosition.row
    targetColumn = screenPosition.column
    baseCharacterWidth = @baseCharacterWidth

    top = targetRow * @lineHeight
    left = 0
    column = 0
    for token in @model.tokenizedLineForScreenRow(targetRow).tokens
      characterWidths = @getScopedCharacterWidths(token.scopes)

      valueIndex = 0
      while valueIndex < token.value.length
        if token.hasPairedCharacter
          char = token.value.substr(valueIndex, 2)
          charLength = 2
          valueIndex += 2
        else
          char = token.value[valueIndex]
          charLength = 1
          valueIndex++

        return {top, left} if column is targetColumn

        left += characterWidths[char] ? baseCharacterWidth unless char is '\0'
        column += charLength
    {top, left}

  hasPixelRectRequirements: ->
    @hasPixelPositionRequirements() and @scrollWidth?

  hasOverlayPositionRequirements: ->
    @hasPixelRectRequirements() and @boundingClientRect? and @windowWidth and @windowHeight

  pixelRectForScreenRange: (screenRange) ->
    if screenRange.end.row > screenRange.start.row
      top = @pixelPositionForScreenPosition(screenRange.start).top
      left = 0
      height = (screenRange.end.row - screenRange.start.row + 1) * @lineHeight
      width = @scrollWidth
    else
      {top, left} = @pixelPositionForScreenPosition(screenRange.start, false)
      height = @lineHeight
      width = @pixelPositionForScreenPosition(screenRange.end, false).left - left

    {top, left, width, height}

  observeDecoration: (decoration) ->
    decorationDisposables = new CompositeDisposable
    decorationDisposables.add decoration.getMarker().onDidChange(@decorationMarkerDidChange.bind(this, decoration))
    if decoration.isType('highlight')
      decorationDisposables.add decoration.onDidFlash(@highlightDidFlash.bind(this, decoration))
    decorationDisposables.add decoration.onDidChangeProperties(@decorationPropertiesDidChange.bind(this, decoration))
    decorationDisposables.add decoration.onDidDestroy =>
      @disposables.remove(decorationDisposables)
      decorationDisposables.dispose()
      @didDestroyDecoration(decoration)
    @disposables.add(decorationDisposables)

  decorationMarkerDidChange: (decoration, change) ->
    if decoration.isType('line') or decoration.isType('gutter')
      return if change.textChanged

      intersectsVisibleRowRange = false
      oldRange = new Range(change.oldTailScreenPosition, change.oldHeadScreenPosition)
      newRange = new Range(change.newTailScreenPosition, change.newHeadScreenPosition)

      if oldRange.intersectsRowRange(@startRow, @endRow - 1)
        @removeFromLineDecorationCaches(decoration, oldRange)
        intersectsVisibleRowRange = true

      if newRange.intersectsRowRange(@startRow, @endRow - 1)
        @addToLineDecorationCaches(decoration, newRange)
        intersectsVisibleRowRange = true

      if intersectsVisibleRowRange
        @shouldUpdateLinesState = true if decoration.isType('line')
        if decoration.isType('line-number')
          @shouldUpdateLineNumbersState = true
        else if decoration.isType('gutter')
          @shouldUpdateCustomGutterDecorationState = true

    if decoration.isType('highlight')
      return if change.textChanged

      @updateHighlightState(decoration)

    if decoration.isType('overlay')
      @shouldUpdateOverlaysState = true

    @emitDidUpdateState()

  decorationPropertiesDidChange: (decoration, event) ->
    {oldProperties} = event
    if decoration.isType('line') or decoration.isType('gutter')
      @removePropertiesFromLineDecorationCaches(
        decoration.id,
        oldProperties,
        decoration.getMarker().getScreenRange())
      @addToLineDecorationCaches(decoration, decoration.getMarker().getScreenRange())
      if decoration.isType('line') or Decoration.isType(oldProperties, 'line')
        @shouldUpdateLinesState = true
      if decoration.isType('line-number') or Decoration.isType(oldProperties, 'line-number')
        @shouldUpdateLineNumbersState = true
      if (decoration.isType('gutter') and not decoration.isType('line-number')) or
      (Decoration.isType(oldProperties, 'gutter') and not Decoration.isType(oldProperties, 'line-number'))
        @shouldUpdateCustomGutterDecorationState = true
    else if decoration.isType('overlay')
      @shouldUpdateOverlaysState = true
    else if decoration.isType('highlight')
      @updateHighlightState(decoration, event)

    @emitDidUpdateState()

  didDestroyDecoration: (decoration) ->
    if decoration.isType('line') or decoration.isType('gutter')
      @removeFromLineDecorationCaches(decoration, decoration.getMarker().getScreenRange())
      @shouldUpdateLinesState = true if decoration.isType('line')
      if decoration.isType('line-number')
        @shouldUpdateLineNumbersState = true
      else if decoration.isType('gutter')
        @shouldUpdateCustomGutterDecorationState = true
    if decoration.isType('highlight')
      @updateHighlightState(decoration)
    if decoration.isType('overlay')
      @shouldUpdateOverlaysState = true

    @emitDidUpdateState()

  highlightDidFlash: (decoration) ->
    flash = decoration.consumeNextFlash()
    if decorationState = @state.content.highlights[decoration.id]
      decorationState.flashCount++
      decorationState.flashClass = flash.class
      decorationState.flashDuration = flash.duration
      @emitDidUpdateState()

  didAddDecoration: (decoration) ->
    @observeDecoration(decoration)

    if decoration.isType('line') or decoration.isType('gutter')
      @addToLineDecorationCaches(decoration, decoration.getMarker().getScreenRange())
      @shouldUpdateLinesState = true if decoration.isType('line')
      if decoration.isType('line-number')
        @shouldUpdateLineNumbersState = true
      else if decoration.isType('gutter')
        @shouldUpdateCustomGutterDecorationState = true
    else if decoration.isType('highlight')
      @updateHighlightState(decoration)
    else if decoration.isType('overlay')
      @shouldUpdateOverlaysState = true

    @emitDidUpdateState()

  updateDecorations: ->
    @lineDecorationsByScreenRow = {}
    @lineNumberDecorationsByScreenRow = {}
    @customGutterDecorationsByGutterNameAndScreenRow = {}
    @highlightDecorationsById = {}

    visibleHighlights = {}
    return unless 0 <= @startRow <= @endRow <= Infinity

    for markerId, decorations of @model.decorationsForScreenRowRange(@startRow, @endRow - 1)
      range = @model.getMarker(markerId).getScreenRange()
      for decoration in decorations
        if decoration.isType('line') or decoration.isType('gutter')
          @addToLineDecorationCaches(decoration, range)
        else if decoration.isType('highlight')
          visibleHighlights[decoration.id] = @updateHighlightState(decoration)

    for id of @state.content.highlights
      unless visibleHighlights[id]
        delete @state.content.highlights[id]

    return

  removeFromLineDecorationCaches: (decoration, range) ->
    @removePropertiesFromLineDecorationCaches(decoration.id, decoration.getProperties(), range)

  removePropertiesFromLineDecorationCaches: (decorationId, decorationProperties, range) ->
    gutterName = decorationProperties.gutterName
    for row in [range.start.row..range.end.row] by 1
      delete @lineDecorationsByScreenRow[row]?[decorationId]
      delete @lineNumberDecorationsByScreenRow[row]?[decorationId]
      delete @customGutterDecorationsByGutterNameAndScreenRow[gutterName]?[row]?[decorationId] if gutterName
    return

  addToLineDecorationCaches: (decoration, range) ->
    marker = decoration.getMarker()
    properties = decoration.getProperties()

    return unless marker.isValid()

    if range.isEmpty()
      return if properties.onlyNonEmpty
    else
      return if properties.onlyEmpty
      omitLastRow = range.end.column is 0

    for row in [range.start.row..range.end.row] by 1
      continue if properties.onlyHead and row isnt marker.getHeadScreenPosition().row
      continue if omitLastRow and row is range.end.row

      if decoration.isType('line')
        @lineDecorationsByScreenRow[row] ?= {}
        @lineDecorationsByScreenRow[row][decoration.id] = decoration

      if decoration.isType('line-number')
        @lineNumberDecorationsByScreenRow[row] ?= {}
        @lineNumberDecorationsByScreenRow[row][decoration.id] = decoration
      else if decoration.isType('gutter')
        gutterName = decoration.getProperties().gutterName
        @customGutterDecorationsByGutterNameAndScreenRow[gutterName] ?= {}
        @customGutterDecorationsByGutterNameAndScreenRow[gutterName][row] ?= {}
        @customGutterDecorationsByGutterNameAndScreenRow[gutterName][row][decoration.id] = decoration

    return

  updateHighlightState: (decoration) ->
    return unless @startRow? and @endRow? and @lineHeight? and @hasPixelPositionRequirements()

    properties = decoration.getProperties()
    marker = decoration.getMarker()
    range = marker.getScreenRange()

    if decoration.isDestroyed() or not marker.isValid() or range.isEmpty() or not range.intersectsRowRange(@startRow, @endRow - 1)
      delete @state.content.highlights[decoration.id]
      @emitDidUpdateState()
      return

    if range.start.row < @startRow
      range.start.row = @startRow
      range.start.column = 0
    if range.end.row >= @endRow
      range.end.row = @endRow
      range.end.column = 0

    if range.isEmpty()
      delete @state.content.highlights[decoration.id]
      @emitDidUpdateState()
      return

    highlightState = @state.content.highlights[decoration.id] ?= {
      flashCount: 0
      flashDuration: null
      flashClass: null
    }
    highlightState.class = properties.class
    highlightState.deprecatedRegionClass = properties.deprecatedRegionClass
    highlightState.regions = @buildHighlightRegions(range)
    @emitDidUpdateState()

    true

  buildHighlightRegions: (screenRange) ->
    lineHeightInPixels = @lineHeight
    startPixelPosition = @pixelPositionForScreenPosition(screenRange.start, true)
    endPixelPosition = @pixelPositionForScreenPosition(screenRange.end, true)
    spannedRows = screenRange.end.row - screenRange.start.row + 1

    if spannedRows is 1
      [
        top: startPixelPosition.top
        height: lineHeightInPixels
        left: startPixelPosition.left
        width: endPixelPosition.left - startPixelPosition.left
      ]
    else
      regions = []

      # First row, extending from selection start to the right side of screen
      regions.push(
        top: startPixelPosition.top
        left: startPixelPosition.left
        height: lineHeightInPixels
        right: 0
      )

      # Middle rows, extending from left side to right side of screen
      if spannedRows > 2
        regions.push(
          top: startPixelPosition.top + lineHeightInPixels
          height: endPixelPosition.top - startPixelPosition.top - lineHeightInPixels
          left: 0
          right: 0
        )

      # Last row, extending from left side of screen to selection end
      if screenRange.end.column > 0
        regions.push(
          top: endPixelPosition.top
          height: lineHeightInPixels
          left: 0
          width: endPixelPosition.left
        )

      regions

  setOverlayDimensions: (decorationId, itemWidth, itemHeight, contentMargin) ->
    @overlayDimensions[decorationId] ?= {}
    overlayState = @overlayDimensions[decorationId]
    dimensionsAreEqual = overlayState.itemWidth is itemWidth and
      overlayState.itemHeight is itemHeight and
      overlayState.contentMargin is contentMargin
    unless dimensionsAreEqual
      overlayState.itemWidth = itemWidth
      overlayState.itemHeight = itemHeight
      overlayState.contentMargin = contentMargin
      @shouldUpdateOverlaysState = true

      @emitDidUpdateState()

  observeCursor: (cursor) ->
    didChangePositionDisposable = cursor.onDidChangePosition =>
      @shouldUpdateHiddenInputState = true if cursor.isLastCursor()
      @pauseCursorBlinking()
      @updateCursorState(cursor)

      @emitDidUpdateState()

    didChangeVisibilityDisposable = cursor.onDidChangeVisibility =>
      @updateCursorState(cursor)

    didDestroyDisposable = cursor.onDidDestroy =>
      @disposables.remove(didChangePositionDisposable)
      @disposables.remove(didChangeVisibilityDisposable)
      @disposables.remove(didDestroyDisposable)
      @shouldUpdateHiddenInputState = true
      @updateCursorState(cursor, true)

      @emitDidUpdateState()

    @disposables.add(didChangePositionDisposable)
    @disposables.add(didChangeVisibilityDisposable)
    @disposables.add(didDestroyDisposable)

  didAddCursor: (cursor) ->
    @observeCursor(cursor)
    @shouldUpdateHiddenInputState = true
    @pauseCursorBlinking()
    @updateCursorState(cursor)

    @emitDidUpdateState()

  startBlinkingCursors: ->
    unless @toggleCursorBlinkHandle
      @state.content.cursorsVisible = true
      @toggleCursorBlinkHandle = setInterval(@toggleCursorBlink.bind(this), @getCursorBlinkPeriod() / 2)

  stopBlinkingCursors: (visible) ->
    if @toggleCursorBlinkHandle
      @state.content.cursorsVisible = visible
      clearInterval(@toggleCursorBlinkHandle)
      @toggleCursorBlinkHandle = null

  toggleCursorBlink: ->
    @state.content.cursorsVisible = not @state.content.cursorsVisible
    @emitDidUpdateState()

  pauseCursorBlinking: ->
    @stopBlinkingCursors(true)
    @startBlinkingCursorsAfterDelay ?= _.debounce(@startBlinkingCursors, @getCursorBlinkResumeDelay())
    @startBlinkingCursorsAfterDelay()
    @emitDidUpdateState()
