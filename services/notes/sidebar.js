.pragma library

function matchesQuery(row, query) {
  return (row.title || "").toLowerCase().indexOf(query) >= 0
      || (row.preview || "").toLowerCase().indexOf(query) >= 0
}

function row(provider, key, source) {
  return { provider: provider.id, notebook: key, kind: source.kind || "note", path: source.path || "",
           title: source.title || "", hasTitle: provider.hasTitle !== false,
           preview: source.preview || "", icon: source.icon || "",
           fixed: source.fixed === true || !provider.canReorder, level: source.level || 0,
           expanded: source.expanded === true, modified: source.modified || "" }
}

function timestamp(value) {
  var result = typeof value === "number" ? value : Date.parse(value || "")
  return isFinite(result) && result > 0 ? result : 0
}

// Reads provider snapshots; never selects, loads, saves, or mutates a provider.
function footerAction(provider, key, action) {
  return { provider: provider.id, section: key, path: action.path, title: action.title,
           icon: action.icon || "", inputPlaceholder: action.inputPlaceholder || "",
           shortcut: action.shortcut || "" }
}

function build(providers, active, query, contentHits) {
  var rows = [], footerActions = [], tabs = [], hits = {}, content = {}
  var q = query.toLowerCase()
  for (var id in contentHits) {
    for (var path in contentHits[id]) {
      content[path] = contentHits[id][path] === true
    }
  }
  providers.forEach(function(provider) {
    if (!active && !(provider.sections || []).length) {
      footerActions = footerActions.concat((provider.footerActions || []).map(function(action) {
        return footerAction(provider, "", action)
      }))
    }
    (provider.sections || []).forEach(function(section) {
      var key = provider.id + "/" + section.key
      var all = section.rows || []
      var notes = section.notes || all.filter(function(item) { return item.kind === "note" })
      var found = q ? notes.filter(function(item) {
        return matchesQuery(item, q) || content[item.path] === true
      }) : []
      tabs.push({ key: key, name: section.name, color: section.color || "", logo: provider.logo || "",
                  count: section.count !== undefined ? section.count : notes.length })
      hits[key] = found.length
      if (key === active) {
        rows = (q ? found : all).map(function(item) { return row(provider, key, item) })
        footerActions = (section.footerActions || []).map(function(action) {
          return footerAction(provider, section.key, action)
        })
      }
    })
  })
  return { rows: rows, footerActions: footerActions, tabs: tabs, hits: hits }
}
