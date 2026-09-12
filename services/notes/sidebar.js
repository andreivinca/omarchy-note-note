.pragma library

function matchesQuery(row, query) {
  return (row.title || "").toLowerCase().indexOf(query) >= 0
      || (row.preview || "").toLowerCase().indexOf(query) >= 0
}

function row(provider, key, source) {
  return { provider: provider.id, notebook: key, kind: source.kind || "note", path: source.path || "",
           title: source.title || "", preview: source.preview || "", icon: source.icon || "",
           fixed: source.fixed === true || !provider.canReorder, level: source.level || 0,
           expanded: source.expanded === true, modified: source.modified || "" }
}

function timestamp(value) {
  var result = typeof value === "number" ? value : Date.parse(value || "")
  return isFinite(result) && result > 0 ? result : 0
}

function dateGroup(value, now) {
  var time = timestamp(value)
  if (!time) {
    return "Notes"
  }
  var today = new Date(now)
  today.setHours(0, 0, 0, 0)
  var yesterday = new Date(today)
  yesterday.setDate(yesterday.getDate() - 1)
  var week = new Date(today)
  week.setDate(week.getDate() - 7)
  var month = new Date(today)
  month.setDate(month.getDate() - 30)
  if (time >= today.getTime()) {
    return "Today"
  }
  if (time >= yesterday.getTime()) {
    return "Yesterday"
  }
  if (time >= week.getTime()) {
    return "Previous 7 Days"
  }
  if (time >= month.getTime()) {
    return "Previous 30 Days"
  }
  return "Older"
}

// Group flat notebooks while preserving the provider's order within each group.
// Trees retain their hierarchy and their provider's section/page order.
function organize(rows, now, groupByDate = true) {
  if (!groupByDate || rows.some(function(item) { return item.kind === "tree" })) {
    return rows
  }
  var names = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older", "Notes"]
  var groups = {}
  var actions = []
  rows.forEach(function(item) {
    if (item.kind !== "note") {
      actions.push(item)
      return
    }
    var name = dateGroup(item.modified, now)
    if (!groups[name]) {
      groups[name] = []
    }
    groups[name].push(Object.assign({}, item, { group: name }))
  })
  var result = []
  names.forEach(function(name) {
    result = result.concat(groups[name] || [])
  })
  return result.concat(actions)
}

// Reads provider snapshots; never selects, loads, saves, or mutates a provider.
function footerAction(provider, key, action) {
  return { provider: provider.id, section: key, path: action.path, title: action.title,
           icon: action.icon || "", inputPlaceholder: action.inputPlaceholder || "",
           shortcut: action.shortcut || "" }
}

function build(providers, active, query, contentHits) {
  var rows = [], footerActions = [], tabs = [], hits = {}, content = {}
  var groupByDate = true
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
        groupByDate = section.groupByDate !== false
        rows = (q ? found : all).map(function(item) { return row(provider, key, item) })
        footerActions = (section.footerActions || []).map(function(action) {
          return footerAction(provider, section.key, action)
        })
      }
    })
  })
  return { rows: rows, footerActions: footerActions, tabs: tabs, hits: hits, groupByDate: groupByDate }
}
