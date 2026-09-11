.pragma library
.import QtQml 2.15 as Qml

function validMonth(year, month) {
  return Number.isInteger(year) && year >= 1 && year <= 9999
    && Number.isInteger(month) && month >= 0 && month < 12
}

function markdown(year, month, locale) {
  if (!validMonth(year, month)) {
    return ""
  }
  // setFullYear also handles years 1–99; Date's numeric constructor adds 1900.
  var first = new Date(0)
  first.setFullYear(year, month, 1)
  first.setHours(12, 0, 0, 0)
  var last = new Date(first)
  last.setMonth(month + 1, 0)
  var firstWeekday = locale.firstDayOfWeek
  var offset = (first.getDay() - firstWeekday + 7) % 7
  var days = last.getDate()
  var headers = []
  for (var weekday = 0; weekday < 7; weekday++) {
    headers.push(locale.standaloneDayName((firstWeekday + weekday) % 7, Qml.Locale.ShortFormat))
  }
  var lines = [
    locale.standaloneMonthName(month, Qml.Locale.LongFormat) + " " + year,
    "",
    "| " + headers.join(" | ") + " |",
    "|---|---|---|---|---|---|---|"
  ]
  // Count calendar dates, not elapsed hours: DST cannot add or skip a day.
  for (var week = 0; week < Math.ceil((offset + days) / 7); week++) {
    var cells = []
    for (var column = 0; column < 7; column++) {
      var day = week * 7 + column - offset + 1
      cells.push(day >= 1 && day <= days ? String(day) : "")
    }
    lines.push("| " + cells.join(" | ") + " |")
  }
  return lines.join("\n")
}
