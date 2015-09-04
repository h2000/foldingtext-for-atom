TaskPaperSyncRules = require '../../sync-rules/taskpaper-sync-rules'
ItemSerializer = require '../../core/item-serializer'
OutlineTextStorage = require './outline-text-storage'
Mutation = require '../../core/mutation'
{CompositeDisposable} = require 'atom'
Outline = require '../../core/outline'
shortid = require '../../core/shortid'
Item = require '../../core/item'
_ = require 'underscore-plus'
Range = require '../range'
assert = require 'assert'

class OutlineEditor

  constructor: (outline, @nativeEditor) ->
    @id = shortid()
    @isUpdatingNativeBuffer = 0
    @isUpdatingOutlineBuffer = 0
    @subscriptions = new CompositeDisposable
    @outlineTextStorage = new OutlineTextStorage(outline, this)
    @nativeEditor ?= new NativeEditor

    @outlineTextStorage.outline.registerAttributeBodyTextSyncRule(TaskPaperSyncRules)

    @subscriptions.add @outlineTextStorage.onWillProcessOutlineMutation (mutation) =>
      targetItem = mutation.target
      if @searchQuery
        if mutation.type is Mutation.CHILDREN_CHANGED and (targetItem is @getHoistedItem() or @getHoistedItem().contains(targetItem))
          for eachItem in mutation.addedItems
            @_addSearchResult eachItem

      if mutation.type is Mutation.CHILDREN_CHANGED
        if not targetItem.hasChildren
          @setCollapsed targetItem

    @subscriptions.add @outlineTextStorage.onDidChange (e) =>
      if not @isUpdatingOutlineBuffer
        range = e.oldCharacterRange
        nsrange = location: range.start, length: range.end - range.start
        @isUpdatingNativeBuffer++
        @nativeEditor.nativeTextBufferReplaceCharactersInRangeWithString(nsrange, e.newText)
        @isUpdatingNativeBuffer--
      assert(@nativeEditor.nativeTextContent is @outlineTextStorage.getText(), 'Text Buffers are Equal')

    @searchQuery = ''
    @expandedBySearch = null
    @setHoistedItem(@outlineTextStorage.outline.root)

  nativeTextBufferDidReplaceCharactersInRangeWithString: (nsrange, string) ->
    if not @isUpdatingNativeBuffer
      range = @outlineTextStorage.getRangeFromCharacterRange(nsrange.location, nsrange.location + nsrange.length)
      @isUpdatingOutlineBuffer++
      @outlineTextStorage.setTextInRange(string, range)
      @isUpdatingOutlineBuffer--

  nativeTextBufferDrawingStateForRange: (nsrange) ->
    range = @outlineTextStorage.getRangeFromCharacterRange(nsrange.location, nsrange.location + nsrange.length)
    linesInRange = @outlineTextStorage.getLinesInRange(range)
    visitedAncestors = new Set(@getHoistedItem())
    visibleItemAncestorRanges = []
    visibleItemStates = []

    for eachLine in linesInRange
      eachItem = eachLine.item
      visibleItemStates.push
        gapBefore: eachItem.previousSibling and not @isVisible(eachItem.previousSibling)
        hasChildren: eachItem.hasChildren
        collapsed: @isCollapsed(eachItem)

      ancestor = eachItem.parent
      while not visitedAncestors.has(ancestor)
        ancestorLine = @outlineTextStorage.getLineForItem(ancestor)
        firstChildLine = @outlineTextStorage.getLineForItem(@getFirstVisibleChild(ancestor))
        lastVisibleDescendantLine = @outlineTextStorage.getLineForItem(@getLastVisibleDescendantOrSelf(ancestor))
        visibleItemAncestorRanges.push
          ancestorStart: ancestorLine.getCharacterOffset() + ancestorLine.getTabCount()
          firstChildStart: firstChildLine.getCharacterOffset()
          lastVisibleDescendantEnd: lastVisibleDescendantLine.getCharacterOffset() + lastVisibleDescendantLine.getCharacterCount() - 1
        visitedAncestors.add(ancestor)
        ancestor = ancestor.parent

    if lastLine = linesInRange[linesInRange.length - 1]
      lastItem = lastLine.item
      if lastItem.nextSibling and not @isVisible(lastItem.nextSibling)
        visibleItemStates[visibleItemStates.length - 1].gapAfter = true

    {} =
      visibleItemAncestorRanges: visibleItemAncestorRanges
      visibleItemStates: visibleItemStates

  destroy: ->
    unless @destroyed
      @outlineTextStorage.destroy()
      @subscriptions.dispose()
      @destroyed = true

  ###
  Section: Hoisted Item
  ###

  hoist: ->
    if item = @getSelectedItems()[0]
      @setHoistedItem(item)

  unhoist: ->
    @setHoistedItem(@outlineTextStorage.outline.root)

  getHoistedItem: ->
    @hoistedItem or @outline.root

  setHoistedItem: (item) ->
    @hoistedItem = item

    @outlineTextStorage.isUpdatingBuffer++
    @outlineTextStorage.removeLines(0, @outlineTextStorage.getLineCount())
    @outlineTextStorage.isUpdatingBuffer--

    newLines = []
    @_gatherLinesForVisibleDescendents(@getHoistedItem(), newLines)
    @outlineTextStorage.isUpdatingBuffer++
    @outlineTextStorage.insertLines(0, newLines)
    @outlineTextStorage.isUpdatingBuffer--

  _gatherLinesForVisibleDescendents: (item, lines) ->
    each = @getFirstVisibleChild(item)
    while each
      lines.push(new OutlineLine(@outlineTextStorage, each))
      @_gatherLinesForVisibleDescendents(each, lines)
      each = @getNextVisibleSibling(each)

  ###
  Section: Matched Items
  ###

  isMatched: (item) ->
    return item and @getItemEditorState(item).matched

  isMatchedAncestor: (item) ->
    return item and @getItemEditorState(item).matchedAncestor

  getQuery: ->
    @searchQuery

  setQuery: (query) ->
    @searchQuery = query

    # Remove old search state from the entire tree
    for each in @outlineTextStorage.outline.root.descendants
      itemState = @getItemEditorState(each)
      itemState.matched = false
      itemState.matchedAncestor = false
      if @expandedBySearch?.has(each)
        itemState.expanded = false

    # Clear the text display buffer
    @outlineTextStorage.isUpdatingBuffer++
    @outlineTextStorage.removeLines(0, @outlineTextStorage.getLineCount())
    @outlineTextStorage.isUpdatingBuffer--
    @expandedBySearch = null

    # Update search state
    if query
      @expandedBySearch = new Set
      for eachItem in @getHoistedItem().evaluateItemPath(query)
        @_addSearchResult(eachItem)

    @nativeEditor.nativeQuery = query
    @setHoistedItem(@getHoistedItem())

  _addSearchResult: (item) ->
    @getItemEditorState(item).matched = true
    ancestor = item.parent
    while ancestor
      ancestorState = @getItemEditorState(ancestor)
      if ancestorState.matchedAncestor
        ancestor = null
      else
        unless ancestorState.expanded
          ancestorState.expanded = true
          @expandedBySearch.add ancestor
        ancestorState.matchedAncestor = true
        ancestor = ancestor.parent

  ###
  Section: Expand & Collapse
  ###

  fold: (items, completely=false) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]

    selectionFoldable = false
    selectionFullyExpanded = true

    for each in items
      if each.hasChildren
        selectionFoldable = true
        unless @isExpanded(each)
          selectionFullyExpanded = false

    if selectionFoldable
      @_setExpandedState items, not selectionFullyExpanded, completely
    else
      parent = items[0].parent
      if @isVisible(parent)
        @setSelectedItemRange(parent, @getHoistedItem().depth - parent.depth)
        @fold(undefined, completely)
        return

  foldCompletely: (items) ->
    @fold(items, true)

  increaseFoldingLevel: ->
    @setFoldingLevel(@getFoldingLevel() + 1)

  decreaseFoldingLevel: ->
    @setFoldingLevel(@getFoldingLevel() - 1)

  getFoldingLevel: ->
    minFoldedDepth = Number.MAX_VALUE
    maxItemDepth = 0

    @outlineTextStorage.iterateLines 0, @outlineTextStorage.getLineCount(), (line) =>
      item = line.item
      depth = item.depth
      if depth > maxItemDepth
        maxItemDepth = depth
      if item.hasChildren and @isCollapsed(item)
        if depth < minFoldedDepth
          minFoldedDepth = item.depth

    if minFoldedDepth is Number.MAX_VALUE
      maxItemDepth
    else
      minFoldedDepth

  setFoldingLevel: (level) ->
    items = @getHoistedItem().descendants
    @setCollapsed((item for item in items when item.depth >= level))
    @setExpanded((item for item in items when item.depth < level))

  isExpanded: (item) ->
    return item and item.hasChildren and @getItemEditorState(item).expanded

  isCollapsed: (item) ->
    return item and item.hasChildren and not @getItemEditorState(item).expanded

  setExpanded: (items) ->
    @_setExpandedState items, true

  setCollapsed: (items) ->
    @_setExpandedState items, false

  expandAll: ->
    @setExpanded(@getHoistedItem().descendants)

  collapseAll: ->
    @setCollapsed(@getHoistedItem().descendants)

  expandToIndentLevel: (level) ->
    collapseItems = []
    expandItems = []

    gather = (item, level) ->
      if level >= 0
        expandItems.push(item)
      else
        collapseItems.push(item)
      for each in item.children
        gather(each, level - 1)

    gather(@getHoistedItem(), level)
    @setCollapsed(collapseItems)
    @setExpanded(expandItems)

  _setExpandedState: (items, expanded, completely=false) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]

    if completely
      newItems = []
      for each in Item.getCommonAncestors(items)
        newItems.push each
        Array.prototype.push.apply(newItems, each.descendants)
      items = newItems

    selectedItemRange = @getSelectedItemRange()

    @outlineTextStorage.isUpdatingBuffer++
    if expanded
      # for better animations
      for each in items
        if not @isVisible(each)
          @getItemEditorState(each).expanded = expanded
      for each in items
        if @isExpanded(each) isnt expanded
          @expandedBySearch?.delete(each)
          @getItemEditorState(each).expanded = expanded
          @_insertVisibleDescendantLines(each)
    else
      # for better animations
      for each in Item.getCommonAncestors(items)
        if @isExpanded(each) isnt expanded
          @getItemEditorState(each).expanded = expanded
          @_removeDescendantLines(each)
      for each in items
        @getItemEditorState(each).expanded = expanded
    @outlineTextStorage.isUpdatingBuffer--

    @setSelectedItemRange(selectedItemRange)

  _insertVisibleDescendantLines: (item) ->
    if itemLine = @outlineTextStorage.getLineForItem(item)
      if each = @getFirstVisibleChild(item)
        insertLines = []
        end = @getNextVisibleItem(@getLastVisibleDescendantOrSelf(item))
        while each isnt end
          insertLines.push(new OutlineLine(@outlineTextStorage, each))
          each = @getNextVisibleItem(each)
        @outlineTextStorage.insertLines(itemLine.getRow() + 1, insertLines)

  _removeDescendantLines: (item) ->
    if itemLine = @outlineTextStorage.getLineForItem(item)
      start = itemLine.getRow() + 1
      end = start
      while item.contains(@outlineTextStorage.getLine(end)?.item)
        end++
      @outlineTextStorage.removeLines(start, end - start)

  ###
  Section: Item Visibility
  ###

  # Public: Determine if an {Item} is visible. An item is visible if it
  # descends from the current hoisted item, and it isn't filtered, and all
  # ancestors up to hoisted node are expanded.
  #
  # - `item` {Item} to test.
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  #
  # Returns {Boolean} indicating if item is visible.
  isVisible: (item, hoistedItem) ->
    parent = item?.parent
    hoistedItem = hoistedItem or @getHoistedItem()
    while parent isnt hoistedItem
      return false unless @isExpanded(parent)
      parent = parent.parent

    if @searchQuery
      itemState = @getItemEditorState(item)
      itemState.matched or itemState.matchedAncestor
    else
      return true

  # Public: Returns first visible {Item} in editor.
  #
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getFirstVisibleItem: (hoistedItem) ->
    hoistedItem = hoistedItem or @getHoistedItem()
    @getNextVisibleItem(hoistedItem, hoistedItem)

  # Public: Returns last visible {Item} in editor.
  #
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getLastVisibleItem: (hoistedItem) ->
    hoistedItem = hoistedItem or @getHoistedItem()
    last = hoistedItem.lastDescendantOrSelf
    if @isVisible(last, hoistedItem)
      last
    else
      @getPreviousVisibleItem(last, hoistedItem)

  # Public: Returns previous visible sibling {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getPreviousVisibleSibling: (item, hoistedItem) ->
    return null unless item

    item = item.previousSibling
    while item
      if @isVisible item, hoistedItem
        return item
      item = item.previousSibling

  # Public: Returns next visible sibling {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getNextVisibleSibling: (item, hoistedItem) ->
    return null unless item

    item = item.nextSibling
    while item
      if @isVisible item, hoistedItem
        return item
      item = item.nextSibling

  # Public: Returns next visible {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getNextVisibleItem: (item, hoistedItem) ->
    return null unless item

    item = item.nextItem
    while item
      if @isVisible item, hoistedItem
        return item
      item = item.nextItem

  # Public: Returns previous visible {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getPreviousVisibleItem: (item, hoistedItem) ->
    return null unless item

    item = item.previousItem
    while item
      if @isVisible item, hoistedItem
        return item
      item = item.previousItem

  # Public: Returns first visible child {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getFirstVisibleChild: (item, hoistedItem) ->
    return null unless item

    firstChild = item.firstChild
    if @isVisible firstChild, hoistedItem
      return firstChild
    @getNextVisibleSibling firstChild, hoistedItem

  # Public: Returns last visible child {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getLastVisibleChild: (item, hoistedItem) ->
    return null unless item

    lastChild = item.lastChild
    if @isVisible lastChild, hoistedItem
      return lastChild
    @getPreviousVisibleSibling lastChild, hoistedItem

  getLastVisibleDescendantOrSelf: (item, hoistedItem) ->
    return null unless item

    lastChild = @getLastVisibleChild item, hoistedItem
    if lastChild
      @getLastVisibleDescendantOrSelf lastChild, hoistedItem
    else
      item

  # Public: Returns previous visible branch {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getPreviousVisibleBranch: (item, hoistedItem) ->
    return null unless item

    previousBranch = item?.previousBranch
    if @isVisible previousBranch, hoistedItem
      previousBranch
    else
      @getPreviousVisibleBranch(previousBranch)

  # Public: Returns next visible branch {Item} relative to given item.
  #
  # - `item` {Item}
  # - `hoistedItem` (optional) Hoisted item {Item} case to consider.
  getNextVisibleBranch: (item, hoistedItem) ->
    return null unless item

    nextBranch = item.nextBranch
    if @isVisible nextBranch, hoistedItem
      nextBranch
    else
      @getNextVisibleBranch nextBranch, hoistedItem

  getVisibleBranchCharacterRange: (item, hoistedItem) ->
    startLine = @outlineTextStorage.getLineForItem(item)
    endLine = @outlineTextStorage.getLineForItem(@getLastVisibleDescendantOrSelf(item, hoistedItem))
    {} =
      start: startLine.getCharacterOffset()
      end: endLine.getCharacterOffset() + endLine.getCharacterCount() - 1

  getVisibleBodyCharacterRange: (item) ->
    line = @outlineTextStorage.getLineForItem(item)
    {} =
      start: line.getTabCount()
      end: line.getCharacterCount() - 1 - line.getTabCount()

  ###
  Section: Selection
  ###

  # Public: Returns the selection {Range}.
  getSelectedRange: ->
    @getSelectedRanges()[0]

  getSelectedRanges: ->
    ranges = []
    #nsranges = @nativeTextBuffer.selectedRanges()
    nsranges = [@nativeEditor.nativeSelectedRange]
    for each in nsranges
      ranges.push @outlineTextStorage.getRangeFromCharacterRange(each.location, each.location + each.length)
    ranges

  getSelectedItems: ->
    selectedItems = []
    for each in @getSelectedRanges()
      rangeItems = (each.item for each in @outlineTextStorage.getLinesInRange(each))
      last = selectedItems[selectedItems.length - 1]
      while rangeItems.length > 0 and rangeItems[0] is last
        rangeItems.shift()
      Array.prototype.push.apply(selectedItems, rangeItems)
    selectedItems

  getSelectedItemRange: ->
    @outlineTextStorage.getItemRangeFromRange(@getSelectedRange())

  # Public: Sets the selection.
  #
  # - `range` {Range}
  setSelectedRange: (range) ->
    @setSelectedRanges([range])

  setSelectedRanges: (ranges) ->
    nsranges = []
    ranges = (@outlineTextStorage.clipRange(each) for each in ranges)
    for each in ranges
      characterRange = @outlineTextStorage.getCharacterRangeFromRange(each)
      nsranges.push
        location: characterRange.start
        length: characterRange.end - characterRange.start
    #@nativeEditor.setSelectedRanges(nsranges)
    @nativeEditor.nativeSelectedRange = nsranges[0]

  setSelectedItemRange: (startItem, spanLocation, endItem, endOffset) ->
    @setSelectedRange(@outlineTextStorage.getRangeFromItemRange(startItem, spanLocation, endItem, endOffset))

  ###
  Section: Insert
  ###

  insertNewline: ->
    outline = @outlineTextStorage.outline
    undoManager = outline.undoManager
    undoManager.beginUndoGrouping()

    selectedRange = @getSelectedRange()
    selectedItemRange = @getSelectedItemRange()

    if not selectedRange.isEmpty()
      @outlineTextStorage.setTextInRange('', selectedRange)
      selectedRange.end = selectedRange.start

    startItem = selectedItemRange.startItem
    startLine = @outlineTextStorage.getLineForItem(startItem)
    spanLocation = selectedItemRange.spanLocation

    match = startItem.bodyText.match(/\t*(- )(.*)/)
    prefix = match?[1] ? ''
    content = match?[2] ? startItem.bodyText
    lead = startLine.getTabCount() + prefix.length

    if spanLocation <= lead and (not prefix or content)
      @insertItem('', true)
      @setSelectedItemRange(startItem, spanLocation)
    else if spanLocation is lead and (prefix and not content)
      startItem.bodyText = ''
    else
      bodyTextOffset = spanLocation - startLine.getTabCount()
      splitText = startItem.getAttributedBodyTextSubstring(bodyTextOffset, -1)
      startItem.replaceBodyTextInRange('', bodyTextOffset, -1)

      if prefix
        splitText.insertStringAtLocation(prefix, 0)
        @insertItem(splitText)
        selectedRange = @getSelectedRange()
        selectedRange.start.column += prefix.length
        selectedRange.end.column += prefix.length
        @setSelectedRange(selectedRange)
      else
        @insertItem(splitText)

    undoManager.endUndoGrouping()

  insertNewlineAbove: (text) ->
    @insertItem(text, true)

  insertNewlineBelow: (text) ->
    @insertItem(text)

  # Public: Insert item at current selection.
  #
  # - `text` Text {String} or {AttributedString} for new item.
  #
  # Returns the new {Item}.
  insertItem: (text, above=false) ->
    text ?= ''

    selectedItems = @getSelectedItems()
    insertBefore
    parent

    if above
      selectedItem = selectedItems[0]
      if not selectedItem
        parent = @getHoistedItem()
        insertBefore = parent.firstChild
      else
        parent = selectedItem.parent
        insertBefore = selectedItem
    else
      selectedItem = selectedItems[selectedItems.length - 1]
      if not selectedItem
        parent = @getHoistedItem()
        insertBefore = null
      else if @isExpanded(selectedItem)
        parent = selectedItem
        insertBefore = parent.firstChild
      else
        parent = selectedItem.parent
        insertBefore = selectedItem.nextSibling

    outline = parent.outline
    insertItem = outline.createItem(text)
    undoManager = outline.undoManager

    undoManager.beginUndoGrouping()
    parent.insertChildBefore(insertItem, insertBefore)
    undoManager.endUndoGrouping()
    @setSelectedItemRange(insertItem, @outlineTextStorage.getLineForItem(insertItem).getTabCount())

    undoManager.setActionName('Insert Item')

    insertItem

  ###
  Section: Move Lines
  ###

  moveLinesUp: (items) ->
    @_moveLinesInDirection(items, 'up')

  moveLinesDown: (items) ->
    @_moveLinesInDirection(items, 'down')

  moveLinesLeft: (items) ->
    @_moveLinesInDirection(items, 'left')

  moveLinesRight: (items) ->
    @_moveLinesInDirection(items, 'right')

  _moveLinesInDirection: (items, direction) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]

    if items.length
      selectedItemRange = @getSelectedItemRange()
      minDepth = @getHoistedItem().depth + 1
      outline = @outlineTextStorage.outline
      firstItem = items[0]
      endItem = items[items.length - 1]
      referenceItem = null
      depthDelta = 0

      switch direction
        when 'up'
          referenceItem = @getPreviousVisibleItem(firstItem)
          unless referenceItem
            return
        when 'down'
          unless nextVisibleItem = @getNextVisibleItem(endItem)
            return
          referenceItem = nextVisibleItem.nextItem
        when 'left'
          depthDelta = -1
          referenceItem = endItem.nextItem
        when 'right'
          depthDelta = 1
          referenceItem = endItem.nextItem

      outline.beginChanges()

      expandItems = []
      disposable = outline.onDidChange (mutation) ->
        if mutation.type is Mutation.CHILDREN_CHANGED
          if not (mutation.target in expandItems)
            expandItems.push mutation.target

      outline.removeItems(items)

      if depthDelta
        for each in items
          each.indent = Math.max(minDepth, each.indent + depthDelta)

      outline.insertItemsBefore(items, referenceItem)

      outline.endChanges =>
        @setExpanded(expandItems)
        disposable.dispose()

      @setSelectedItemRange(selectedItemRange)

  ###
  Section: Move Branches
  ###

  moveBranchesUp: (items) ->
    @_moveBranchesInDirection(items, 'up')

  moveBranchesDown: (items) ->
    @_moveBranchesInDirection(items, 'down')

  moveBranchesLeft: (items) ->
    @_moveBranchesInDirection(items, 'left')

  moveBranchesRight: (items) ->
    @_moveBranchesInDirection(items, 'right')

  _moveBranchesInDirection: (items, direction) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]
    items = Item.getCommonAncestors(items)

    if items.length > 0
      startItem = items[0]
      newNextSibling
      newParent

      if direction is 'up'
        newNextSibling = @getPreviousVisibleSibling(startItem)
        if newNextSibling
          newParent = newNextSibling.parent
      else if direction is 'down'
        endItem = items[items.length - 1]
        newPreviousSibling = @getNextVisibleSibling(endItem)
        if newPreviousSibling
          newParent = newPreviousSibling.parent
          newNextSibling = @getNextVisibleSibling(newPreviousSibling)
      else if direction is 'left'
        startItemParent = startItem.parent
        if startItemParent isnt @getHoistedItem()
          newParent = startItemParent.parent
          newNextSibling = @getNextVisibleSibling(startItemParent)
          while newNextSibling and newNextSibling in items
            newNextSibling = @getNextVisibleSibling(newNextSibling)
      else if direction is 'right'
        newParent = @getPreviousVisibleSibling(startItem)

      if newParent
        @moveBranches(items, newParent, newNextSibling)

  groupBranches: (items) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]
    items = Item.getCommonAncestors(items)

    if items.length > 0
      outline = @outlineTextStorage.outline
      first = items[0]
      group = outline.createItem ''

      undoManager = outline.undoManager
      undoManager.beginUndoGrouping()

      first.parent.insertChildBefore group, first
      @setSelectedItemRange group, group.depth - @getHoistedItem().depth
      @moveBranches items, group

      undoManager.endUndoGrouping()
      undoManager.setActionName('Group Items')

  duplicateBranches: (items) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]
    items = Item.getCommonAncestors(items)

    if items.length > 0
      itemRange = @getSelectedItemRange()
      outline = @outlineTextStorage.outline
      expandedClones = []
      clonedItems = []

      for each in items
        clonedItems.push each.cloneItem (oldID, cloneID, cloneItem) =>
          oldItem = outline.getItemForID(oldID)
          if oldItem is itemRange.startItem
            itemRange.startItem = cloneItem
          if oldItem is itemRange.endItem
            itemRange.endItem = cloneItem
          if @isExpanded(oldItem)
            expandedClones.push(cloneItem)

      last = items[items.length - 1]
      insertBefore = last.nextSibling
      parent = insertBefore?.parent ? items[0].parent
      undoManager = outline.undoManager

      undoManager.beginUndoGrouping()
      @setExpanded(expandedClones)
      parent.insertChildrenBefore(clonedItems, insertBefore)
      @setSelectedItemRange(itemRange)
      undoManager.endUndoGrouping()
      undoManager.setActionName('Duplicate Items')

  promoteChildBranches: (item) ->
    item ?= @getSelectedItems()[0]
    if item
      @moveBranches(item.children, item.parent, item.nextSibling)
      @outlineTextStorage.outline.undoManager.setActionName('Promote Children')

  demoteTrailingSiblingBranches: (item) ->
    item ?= @getSelectedItems()[0]
    if item
      trailingSiblings = []

      each = item.nextSibling
      while each
        trailingSiblings.push(each)
        each = each.nextSibling

      if trailingSiblings.length > 0
        @moveBranches(trailingSiblings, item, null)
        @outlineTextStorage.outline.undoManager.setActionName('Demote Siblings')

  moveBranches: (items, newParent, newNextSibling) ->
    items ?= @getSelectedItems()
    if not _.isArray(items)
      items = [items]
    items = Item.getCommonAncestors(items)

    outline = @outlineTextStorage.outline

    undoManager = outline.undoManager
    undoManager.beginUndoGrouping()

    selectedItemRange = @getSelectedItemRange()
    newParentNeedsExpand =
      newParent isnt @getHoistedItem() and
      not @isExpanded(newParent) and
      @isVisible(newParent)

    outline.beginChanges()
    outline.removeItemsFromParents items
    newParent.insertChildrenBefore items, newNextSibling
    outline.endChanges()

    if newParentNeedsExpand
      @setExpanded(newParent)
    @setSelectedItemRange(selectedItemRange)

    undoManager.endUndoGrouping()
    undoManager.setActionName('Move Items')

  ###
  Section: Serialization
  ###

  serialize: (mimeType) ->
    ItemSerializer.serializeItems(@outlineTextStorage.outline.root.children, self, 'text/plain')

  deserialize: (data, mimeType) ->
    items = ItemSerializer.deserializeItems(data, @outlineTextStorage.outline, 'text/plain')

  ###
  Section: Scripting
  ###

  evaluateScript: (script, options) ->
    result = '_wrappedValue': null
    try
      if options
        options = JSON.parse(options)._wrappedValue
      func = eval("(#{script})")
      r = func(this, options)
      if r is undefined
        r = null # survive JSON round trip
      result._wrappedValue = r
    catch e
      result._wrappedValue = "#{e.toString()}\n\tUse the Help > SDKRunner to debug"
    JSON.stringify(result)

  ###
  Section: Item Editor State
  ###

  getItemEditorState: (item) ->
    if item
      unless state = item.getUserData(@id)
        state = new ItemEditorState
        item.setUserData @id, state
      state

class ItemEditorState
  constructor: ->
    @marked = false
    @selected = false
    @expanded = true
    @matched = false
    @matchedAncestor = false

class NativeEditor
  constructor: ->
    @text = ''
    @query = ''
    @selectedRange =
      location: 0
      length: 0

  Object.defineProperty @::, 'nativeQuery',
    get: ->
      @query

    set: (@query) ->

  Object.defineProperty @::, 'nativeSelectedRange',
    get: ->
      @selectedRange.location = Math.min(@selectedRange.location, @text.length)
      @selectedRange.length = Math.min(@selectedRange.length, @text.length - @selectedRange.location)
      @selectedRange

    set: (@selectedRange) ->

  Object.defineProperty @::, 'nativeTextContent',
    get: -> @text

  nativeTextBufferReplaceCharactersInRangeWithString: (range, text) ->
    @text = @text.substring(0, range.location) + text + @text.substring(range.location + range.length)

module.exports = OutlineEditor