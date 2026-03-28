-- Custom expectations for mini.test
local H = {}

H.expect = MiniTest.expect
H.eq = MiniTest.expect.equality
H.not_eq = MiniTest.expect.no_equality

---Custom expectation: string contains pattern
---@param pattern string
---@param str string
---@return boolean
H.expect_contains = MiniTest.new_expectation("string contains", function(pattern, str)
  if type(str) ~= "string" then
    return false
  end
  return str:find(pattern, 1, true) ~= nil
end, function(pattern, str)
  return string.format(
    "\nExpected string to contain:\n%s\n\nActual:\n%s",
    vim.inspect(pattern),
    type(str) == "string" and str or vim.inspect(str)
  )
end)

---Custom expectation: table contains value
---@param value any
---@param tbl table
---@return boolean
H.expect_tbl_contains = MiniTest.new_expectation("table contains", function(value, tbl)
  if type(tbl) ~= "table" then
    return false
  end
  for k, v in pairs(tbl) do
    if k == value or v == value then
      return true
    end
  end
  return false
end, function(value, tbl)
  return string.format(
    "\nExpected table to contain:\n%s\n\nActual:\n%s",
    vim.inspect(value),
    type(tbl) == "table" and vim.inspect(tbl) or vim.inspect(tbl)
  )
end)

return H
