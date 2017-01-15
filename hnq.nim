import asyncdispatch, asynchttpserver, httpclient, os, streams, xmltree, parsexml, xmlparser, strutils, sequtils

type Rule = tuple[site: string, tags: seq[string]]

proc parseRule(rule: string): Rule =
    let rs = rule.split(':', 2)
    let site = try: rs[0]
               except IndexError: ""
    let otags = try: rs[1]
                except IndexError: ""
    var tags: seq[string]
    if otags == "*":
        tags = @[]
    else:
        tags = otags.split(',')
    return (site: site, tags: tags)

proc parsePred(query: string): seq[Rule] =
    if query == "*":
        return @[]
    let spl = query.split('|')
    if spl.len() == 0:
        return @[]
    return spl.map(parseRule)

proc matchesRule(entry: XmlNode, rule: Rule): bool =
    var matchedSite = false
    if rule.site != "*" and rule.site.len() > 0:
        let link = entry.child("link").attr("href")
        if not link.startsWith("http://" & rule.site):
            return false
        matchedSite = true

    if rule.tags.len() == 0:
        return matchedSite

    let tags = entry.findAll("category").map(proc(el: XmlNode): string = el.attr("term"))

    if tags.len() == 0:
        return matchedSite

    for tag in tags:
        if tag in rule.tags:
            return true
    return false

proc filterInPlace(doc: XmlNode, pred: proc (entry: XmlNode): bool) =
    # we are mutating the doc in the loop, hence this is not a regular enumerate->map
    var current = 0

    while current < doc.len():
        let elem = doc[current]
        if elem.tag != "entry":
            # relay non-entries as is
            inc current
            continue
        if not pred(elem):
            # if this entry is not required, we delete it
            doc.delete(current)
            # the current counter has now shifted back, so we move forward
            # without incrementing the counter
            continue
        # else move forward
        inc current

proc runQuery(doc: XmlNode, excludeQuery: string, includeQuery: string) =
    # by default, every thing is included, hence * is meaningless
    let hasPassedIncludes = includeQuery != "*" and includeQuery.len() > 0
    if hasPassedIncludes:
        var includeRules = parsePred(includeQuery)

        proc onlyIncludes(entry: XmlNode): bool =
            for rule in includeRules:
                if matchesRule(entry, rule):
                    return true # it matched an include, so we will keep it
            return false # didn't match any include, hence mark for deletion

        filterInPlace(doc, onlyIncludes)

    if excludeQuery == "*" and not hasPassedIncludes:
        # remove all the things!
        filterInPlace(doc, proc(el: XmlNode): bool = true)
    
    if excludeQuery.len() > 0:
        let excludeRules = parsePred(excludeQuery)

        proc removeExcludes(entry: XmlNode): bool =
            for rule in excludeRules:
                if matchesRule(entry, rule):
                    return false # it matched an exclude rule, hence mark for deletion
            return true # didn't match any exclude rule, so let it be

        filterInPlace(doc, removeExcludes) # delete all which match any exclude rule

proc main() {.async.} =
    let port: uint = try: parseUInt(paramStr(1))
                     except: 8080
    var server = newAsyncHttpServer()
    echo "Serving at port " & $(port)
    proc cb(req: Request) {.async.} =
        if $(req.reqMethod) != "GET":
            waitFor req.respond(Http400, "vulnerabilities not yet implemented")
        else:
            let queries = req.url.query.split('&')
            var includeQuery = ""
            var excludeQuery = ""
            for query in queries:
                let qsplit = query.split('=')
                let key = try: qsplit[0]
                          except IndexError: ""
                let val = try: qsplit[1]
                          except IndexError: ""
                if key == "include":
                    includeQuery = val
                if key == "exclude":
                    excludeQuery = val
            let client = newAsyncHttpClient()
            let resp = await client.getContent("http://stackexchange.com/feeds/questions")
            let doc = parseXml(newStringStream(resp))
            runQuery(doc, excludeQuery, includeQuery)
            waitFor req.respond(Http200, $(doc))
    waitFor server.serve(Port(port), cb)

waitFor main()
