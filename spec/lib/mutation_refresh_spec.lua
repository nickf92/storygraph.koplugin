local loadApp = require("spec/support/load_app")
describe("Best-effort refresh after note confirmation", function()
  it("ignores refresh results when the document session changes during the GET", function()
    local app, job
    app=loadApp {
      ["ui/network/manager"]={isConnected=function() return true end},
      ["ui/uimanager"]={nextTick=function(_,fn) job=fn end},
      ["ui/trapper"]={wrap=function(_,fn) fn() end},
      ["storygraph/lib/hardcover_api"]={findUserBook=function()
        app._documentSessionId="new-session"
        return {id="book",status_id=2}
      end},
    }
    app._documentSessionId="old-session"
    app.ui={document={file="book.epub"}}
    app.settings={getLinkedBookId=function() return "book" end}
    app.state={book_status={}}
    app:_refreshAfterMutation {document="book.epub",book_id="book"}
    job()
    assert.is_nil(app.state.book_status.id)
  end)

  it("does not retry a failed refresh or alter the confirmed delivery", function()
    local job,calls= nil,0
    local app=loadApp {
      ["ui/network/manager"]={isConnected=function() return true end},
      ["ui/uimanager"]={nextTick=function(_,fn) job=fn end},
      ["ui/trapper"]={wrap=function(_,fn) fn() end},
      ["storygraph/lib/hardcover_api"]={findUserBook=function() calls=calls+1;error("read failed") end},
    }
    app.ui={document={file="book.epub"}}
    app.settings={getLinkedBookId=function() return "book" end}
    app.state={book_status={id="book"}}
    app:_refreshAfterMutation {document="book.epub",book_id="book"}
    job()
    assert.are.equal(1,calls)
    assert.are.equal("book",app.state.book_status.id)
  end)
end)
