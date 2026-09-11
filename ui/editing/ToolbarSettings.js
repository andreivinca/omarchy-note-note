.pragma library

// Each inner array is a visual group. Dropdown items use the same tool ids
// as direct buttons; placement belongs to settings, never to a tool file.
function defaults() {
  return [
    ["bold", "italic", "underline", "strikeout"],
    ["textColor", "highlight", "code", "heading"],
    ["ul", "ol", "todo", "outdent", "indent"],
    ["quote", "codeblock", "link"],
    ["table", "addRow", "delRow", "addCol", "delCol"],
    [{ dropdown: "insert", items: [
      { dropdown: "insertMonth", items: ["currentMonth", "nextMonth", "customMonth"] },
      "rule"
    ] }]
  ]
}

function validate(layout) {
  if (!Array.isArray(layout)) {
    return "editor.toolbar must be an array of groups"
  }
  var seen = Object.create(null)
  function claim(id) {
    if (typeof id !== "string" || !id.trim()) {
      return "Toolbar tool ids must be nonempty strings"
    }
    if (seen[id]) {
      return "Toolbar tool appears more than once: " + id
    }
    seen[id] = true
    return ""
  }
  function validateEntry(entry) {
    if (typeof entry === "string") {
      return claim(entry)
    }
    if (!entry || typeof entry !== "object" || Array.isArray(entry)
        || !Array.isArray(entry.items)) {
      return "Toolbar entries must be tool ids or {\"dropdown\": \"id\", \"items\": [...]}"
    }
    var error = claim(entry.dropdown)
    for (var i = 0; !error && i < entry.items.length; i++) {
      error = validateEntry(entry.items[i])
    }
    return error
  }
  for (var g = 0; g < layout.length; g++) {
    var group = layout[g]
    if (!Array.isArray(group)) {
      return "Each editor.toolbar group must be an array"
    }
    for (var i = 0; i < group.length; i++) {
      var error = validateEntry(group[i])
      if (error) {
        return error
      }
    }
  }
  return ""
}

function validateConfig(config) {
  if (config.editor === undefined) {
    return ""
  }
  if (!config.editor || typeof config.editor !== "object" || Array.isArray(config.editor)) {
    return "editor settings must be an object"
  }
  return config.editor.toolbar === undefined ? "" : validate(config.editor.toolbar)
}

function editorDefaults(settings) {
  var result = settings && typeof settings === "object" && !Array.isArray(settings)
    ? Object.assign({}, settings) : {}
  if (validate(result.toolbar)) {
    result.toolbar = defaults()
  }
  return result
}

function resolve(layout, tools) {
  var groups = validate(layout) ? defaults() : layout
  var byId = Object.create(null)
  var placed = Object.create(null)
  var menus = Object.create(null)
  var toolbar = []
  for (var t = 0; t < tools.length; t++) {
    var installed = tools[t]
    byId[installed.toolId] = installed
    // Old layouts may name individual choices. Keep the combined tool at
    // the first such position, including when it lives inside another menu.
    for (var o = 0; o < (installed.options || []).length; o++) {
      byId[installed.options[o].toolId] = installed
    }
  }
  function resolveEntry(entry) {
    var isDropdown = typeof entry === "object"
    var id = isDropdown ? entry.dropdown : entry
    var tool = byId[id]
    var configurableMenu = tool && tool.isMenu && (tool.options || []).length === 0
    if (!tool || configurableMenu !== isDropdown || placed[tool.toolId]) {
      return null
    }
    id = tool.toolId
    placed[id] = true
    if (isDropdown) {
      menus[id] = []
      for (var i = 0; i < entry.items.length; i++) {
        var child = resolveEntry(entry.items[i])
        if (child) {
          menus[id].push(child)
        }
      }
    }
    return tool
  }
  for (var g = 0; g < groups.length; g++) {
    for (var i = 0; i < groups[g].length; i++) {
      var tool = resolveEntry(groups[g][i])
      if (tool) {
        toolbar.push({ tool: tool, group: g })
      }
    }
  }
  // Omission never hides an installed tool. Extensions appear predictably
  // without requiring a settings edit, even when their old menu was removed.
  var remaining = tools.filter(function(tool) {
    return !placed[tool.toolId]
  }).sort(function(a, b) {
    return a.toolId.localeCompare(b.toolId)
  })
  for (var r = 0; r < remaining.length; r++) {
    toolbar.push({ tool: remaining[r], group: groups.length })
  }
  return { toolbar: toolbar, menus: menus }
}
