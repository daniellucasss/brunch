'use strict'

debug = require('debug')('brunch:file-list')
util = require 'util'
EventEmitter = require('events').EventEmitter
normalize = require('path').normalize
fcache = require 'fcache'
Asset = require './asset'
SourceFile = require './source_file'
formatError = require('../helpers').formatError

startsWith = (string, substring) ->
  string.lastIndexOf(substring, 0) is 0

### A list of `fs_utils.SourceFile` or `fs_utils.Asset`
# with some additional methods used to simplify file reading / removing. ###
module.exports = class FileList
  ### Maximum time between changes of two files that will be considered
  # as a one compilation. ###
  resetTime: 65

  constructor: (@config) ->
    EventEmitter.call(this)
    @files = []
    @assets = []
    @on 'change', @_change
    @on 'unlink', @_unlink
    @compiling = {}
    @compiled = {}
    @copying = {}
    @initial = true
    interval = @config.fileListInterval
    @resetTime = interval if typeof interval is 'number'

  getAssetErrors: ->
    invalidAssets = @assets.filter((asset) -> asset.error?)
    if invalidAssets.length > 0
      invalidAssets.map (invalidAsset) ->
        formatError invalidAsset.error, invalidAsset.path
    else
      null

  # Files that are not really app files.
  isIgnored: (path, test = @config.conventions.ignored) ->
    return true if @config._normalized.paths.allConfigFiles.indexOf(path) >= 0

    switch toString.call(test).slice(8, -1)
      when 'RegExp'
        path.match test
      when 'Function'
        test path
      when 'String'
        startsWith normalize(path), normalize(test)
      when 'Array'
        test.some((subTest) => @isIgnored path, subTest)
      else
        false

  is: (name, path) ->
    convention = @config._normalized.conventions[name]
    return false unless convention
    if typeof convention isnt 'function'
      throw new TypeError "Invalid convention #{convention}"
    convention path

  # Called every time any file was changed.
  # Emits `ready` event after `resetTime`.
  resetTimer: =>
    clearTimeout @timer if @timer?
    @timer = setTimeout =>
      # Clean disposed files.
      @files = @files.filter (file) -> not file.disposed

      if Object.keys(@compiling).length is 0 and Object.keys(@copying).length is 0
        @emit 'ready'
        @compiled = {}
      else
        @resetTimer()
    , @resetTime

  find: (path) ->
    @files.filter((file) -> file.path is path)[0]

  findAsset: (path) ->
    @assets.filter((file) -> file.path is path)[0]

  compileDependencyParents: (path) ->
    compiled = @compiled
    parents = @files
      .filter (dependent) ->
        dependent.dependencies and
        dependent.dependencies.length > 0 and
        dependent.dependencies.indexOf(path) >= 0 and
        not compiled[dependent.path]

    if parents.length
      parentsList = parents.map((_) -> _.path).join ', '
      debug "Compiling dependency '#{path}' parent(s): #{parentsList}"
      parents.forEach @compile

  compile: (file) =>
    file.removed = false
    path = file.path
    if @compiling[path]
      @resetTimer()
    else
      @compiling[path] = true
      file.compile (error) =>
        delete @compiling[path]
        @resetTimer()
        return if error?
        debug "Compiled file '#{path}'..."
        @compiled[path] = true
        @emit 'compiled', path

  copy: (asset) =>
    path = asset.path
    @copying[path] = true
    asset.copy (error) =>
      delete @copying[path]
      @resetTimer()
      return if error?
      debug "Copied asset '#{path}'"

  _add: (path, compiler, linters, isHelper) ->
    isVendor = @is 'vendor', path
    wrapper = @config._normalized.modules.wrapper
    file = new SourceFile path, compiler, linters, wrapper, isHelper, isVendor
    @files.push file
    file

  _addAsset: (path) ->
    file = new Asset path, @config.paths.public, @config._normalized.conventions.assets
    @assets.push file
    file

  _change: (path, compiler, linters, isHelper) =>
    ignored = @isIgnored path
    if @is 'assets', path
      unless ignored
        file = @findAsset(path) or @_addAsset path
        @copy file
    else
      debug "Reading '#{path}'"
      fcache.updateCache path, (error, source) =>
        if error
          return console.log 'Reading', error if error?
        if not ignored and (compiler and compiler.length)
          sourceFile = @find(path) or @_add path, compiler, linters, isHelper
          @compile sourceFile

        @compileDependencyParents path unless @initial

  _unlink: (path) =>
    ignored = @isIgnored path
    if @is 'assets', path
      unless ignored
        @assets.splice(@assets.indexOf(path), 1)
    else
      if ignored
        @compileDependencyParents path
      else
        file = @find path
        file.removed = true if file and not file.disposed
    @resetTimer()

FileList.prototype.__proto__ = EventEmitter.prototype
