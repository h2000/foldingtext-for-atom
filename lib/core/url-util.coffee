_ = require 'underscore-plus'
path = require 'path'
url = require 'url'
fs = require 'fs'

relativeFileURLHREF = (fromFileURL, toFileURL, options={}) ->
  toPathnameAndOptions = fileURLToPathnameAndOptions(toFileURL)
  toPathname = toPathnameAndOptions.pathname
  fromPathnameAndOptions = fileURLToPathnameAndOptions(fromFileURL)
  fromPathname = fromPathnameAndOptions.pathname
  finalURLlObject = {}
  finalPathname = ''

  unless fromPathnameAndOptions.pathname is '.'
    unless fromPathname is toPathname
      if fs.statSync(fromPathname).isFile()
        fromPathname = path.dirname(fromPathname)
      finalPathname = path.relative(fromPathname, toPathname)
  else
    finalPathname = toPathnameAndOptions.pathname

  finalURLlObject.pathname = finalPathname
  if path.isAbsolute(finalPathname)
    finalURLlObject.protocol = 'file'
    finalURLlObject.slashes = true

  # Merge options and use as hash and query params
  options = _.clone(options)
  options[key] ?= value for key, value of toPathnameAndOptions.options
  options[key] ?= value for key, value of fromPathnameAndOptions.options
  if options.hash
    finalURLlObject.hash = options.hash.substr(1)
    delete options.hash
  finalURLlObject.query = options

  url.format(finalURLlObject)

pathnameAndOptionsToFileURL = (pathname, options) ->
  pathname = path.resolve(pathname)
  pathname = pathname.replace(/\\/g, '/')
  pathname = (encodeURIComponent(each) for each in pathname.split('/')).join('/')

  options ?= {}
  hash = options.hash
  if hash
    delete options.hash

  urlObject =
    protocol: 'file'
    pathname: pathname
    slashes: true
    query: options
    hash: hash

  url.format(urlObject)

fileURLToPathnameAndOptions = (fileURL) ->
  urlObject = null
  if _.isString(fileURL)
    urlObject = url.parse(fileURL, true)
  else
    urlObject = fileURL
  pathname = urlObject.pathname ? ''
  options = {}

  # Detect windows drive letter and then Handle leading / in pathname of
  # a windows file URL such as file:///C:/hello.txt
  if pathname.match(/^\/[a-zA-Z]:/)
    pathname = pathname.substr(1)
  pathname = (decodeURIComponent(each) for each in pathname.split('/')).join(path.sep)
  pathname = path.normalize(pathname)

  if urlObject.hash
    options.hash ?= urlObject.hash.substr(1)
  options[key] ?= value for key, value of urlObject.query

  {} =
    pathname: pathname
    options: options

module.exports =
  relativeFileURLHREF: relativeFileURLHREF
  pathnameAndOptionsToFileURL: pathnameAndOptionsToFileURL
  fileURLToPathnameAndOptions: fileURLToPathnameAndOptions