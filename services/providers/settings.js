.pragma library

function equal(a, b) {
  if (a === b) {
    return true
  }
  if (!a || !b || typeof a !== "object" || typeof b !== "object") {
    return false
  }
  var keys = Object.keys(a), other = Object.keys(b)
  if (keys.length !== other.length) {
    return false
  }
  return keys.every(function(key) { return key in b && equal(a[key], b[key]) })
}

function resources(entry) {
  var result = {}
  for (var key in entry) {
    if (key !== "enabled" && key !== "notebookTabs") {
      result[key] = entry[key]
    }
  }
  return result
}

function plan(oldConfig, newConfig, ids) {
  return ids.map(function(id) {
    var before = (oldConfig.providers || {})[id] || {}
    var after = (newConfig.providers || {})[id] || {}
    var was = before.enabled !== false, now = after.enabled !== false
    return { id: id, enabled: now,
             replace: was !== now || (now && !equal(resources(before), resources(after))),
             presentation: was && now && before.notebookTabs !== after.notebookTabs }
  }).filter(function(change) { return change.replace || change.presentation })
}
