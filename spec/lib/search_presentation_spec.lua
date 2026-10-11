local loadUI = require("spec/support/load_ui")
local SearchDialog = loadUI("storygraph/lib/ui/search_dialog.lua", {
  ["ui/widget/container/inputcontainer"] = {extend=function(_,class) return class end},
  ["ui/size"] = {border={window=1}},
})

describe("Book and edition presentation", function()
  local book
  before_each(function()
    book={book_id="edition-1",title="A very long book title",pages=288,
      edition_format="Paperback",edition_language="Italian",publisher="Publisher",pub_date="2018",
      isbn="9780000000001",contributions={},users_count=12,cached_image={url="cover.jpg",width=60,height=90}}
  end)

  it("preserves metadata, selection IDs and lazy covers in both rendering modes",function()
    for _,compatibility in ipairs({true,false}) do
      local dialog=setmetatable({compatibility_mode=compatibility},{__index=SearchDialog})
      local item=dialog:createListItem(book,{book_id="edition-1"})
      local text=compatibility and item.text or item.authors
      assert.matches("Paperback · Italian · 288 pages",text,1,true)
      assert.matches("Publisher · 2018",text,1,true)
      assert.matches("ISBN: 9780000000001",text,1,true)
      assert.are.equal(book.book_id,item.book_id)
      assert.is_true(item.highlight)
      assert.matches("Linked edition",item.mandatory,1,true)
      assert.matches("12 readers",item.mandatory,1,true)
      assert.are.equal("cover.jpg",item.cover_url)
      assert.is_true(item.lazy_load_cover)
    end
  end)

  it("keeps author information when the result also has page metadata",function()
    book={book_id="book",title="Book",pages=100,contributions={{author={name="Writer"}}}}
    for _,compatibility in ipairs({true,false}) do
      local item=SearchDialog.createListItem({compatibility_mode=compatibility},book)
      local text=compatibility and item.text or item.authors
      assert.matches("Writer",text,1,true)
      assert.matches("100 pages",text,1,true)
    end
  end)

  it("omits missing edition metadata without altering the selectable book",function()
    book={book_id="book",title="Book",contributions={}}
    local item=SearchDialog.createListItem({compatibility_mode=true},book)
    assert.are.equal("Book",item.text)
    assert.are.equal("book",item.book_id)
    assert.is_nil(item.cover_url)
  end)
end)
