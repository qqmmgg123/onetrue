# -*- coding: utf-8 -*-
from pathlib import Path

path = Path(r"D:\zufang\share-web\components\AppShell.js")
text = path.read_text(encoding="utf-8")

start = text.find("  return (\n    <div className={shellClass}>")
end = text.find("      <main className=\"main\">")
if start < 0 or end < 0:
    raise SystemExit(f"markers not found start={start} end={end}")

new_block = r'''  return (
    <div className={shellClass}>
      <AppHeader
        narrow={narrow}
        railOpen={sideOpen}
        onToggleRail={() => setSideOpen((v) => !v)}
        onOpenAuth={openAuth}
        onOpenSettings={openAccountSettings}
      />
      <button
        type="button"
        className="side-backdrop"
        aria-label="关闭菜单"
        onClick={() => setSideOpen(false)}
      />

      <div className="shell-body">
      <aside className="side">
        <nav className="side-nav" aria-label="主导航">
          {NAV.map(({ id, label, Icon }) => (
            <button
              key={id}
              type="button"
              className={`side-nav-btn${nav === id ? " active" : ""}`}
              onClick={() => goNav(id)}
            >
              <Icon filled={nav === id} />
              <span className="side-nav-label">{label}</span>
            </button>
          ))}
        </nav>

        <div className="side-section">
          {nav === "notes" ? (
            <div className="side-section-label">笔记</div>
          ) : null}
          {nav === "explore" ? (
            <div className="side-section-label">阅读</div>
          ) : null}
          {nav === "other" ? (
            <div className="side-section-label">其他</div>
          ) : null}
          {nav === "memo" || nav === "calendar" ? (
            <div className="side-hint">
              {nav === "memo"
                ? "备忘在右侧主区浏览与编辑"
                : "日常日程在右侧主区查看"}
            </div>
          ) : null}

          <div
            className="side-section-body"
            onScroll={(e) => {
              if (nav !== "notes" || !isLoggedIn) return;
              if (!notesHasMore || notesLoadingMore || notesLoading) return;
              const el = e.currentTarget;
              if (el.scrollHeight - el.scrollTop - el.clientHeight < 96) {
                loadNotesPage({ reset: false });
              }
            }}
          >
            {nav === "notes" ? (
              <>
                <HubRow
                  title="＋ 新笔记"
                  summary="写一篇新的笔记"
                  action=""
                  active={
                    mode === "compose" &&
                    !composeNote?.id &&
                    (composeKind === "note" || !composeKind)
                  }
                  onClick={() => {
                    if (!isLoggedIn) return needLogin();
                    setSideOpen(false);
                    openCompose(null, { kind: "note" });
                  }}
                />
                {authLoading || (isLoggedIn && (hubLoading || notesLoading)) ? (
                  <div className="middle-loading">加载笔记中…</div>
                ) : !isLoggedIn ? (
                  <div className="side-hint">登录后查看笔记列表</div>
                ) : (
                  <>
                    {noteList.map((n) => (
                      <HubRow
                        key={n.id}
                        title={displayTitle(n.title, n.body, "无标题", n.format)}
                        summary={formatWhen(n.updatedAt)}
                        action=""
                        active={mode === "compose" && composeNote?.id === n.id}
                        onClick={() => {
                          setSideOpen(false);
                          openCompose(n);
                        }}
                        deleting={deletingNoteId === n.id}
                        onDelete={() => confirmDeleteNote(n)}
                      />
                    ))}
                    {noteList.length === 0 ? (
                      <div className="side-hint">还没有笔记</div>
                    ) : null}
                    {notesLoadingMore ? (
                      <div className="middle-load-more">加载更多…</div>
                    ) : null}
                    {!notesLoadingMore && notesHasMore && noteList.length > 0 ? (
                      <button
                        type="button"
                        className="middle-load-more"
                        style={{
                          width: "100%",
                          border: 0,
                          background: "transparent",
                        }}
                        onClick={() => loadNotesPage({ reset: false })}
                      >
                        点击加载更多
                      </button>
                    ) : null}
                  </>
                )}
              </>
            ) : null}

            {nav === "explore" ? (
              <>
                {EXPLORE_TABS.map((t) => (
                  <HubRow
                    key={t.id}
                    title={t.id === "publish" ? "＋ 发布文章" : t.label}
                    summary=""
                    action=""
                    active={
                      t.id === "publish"
                        ? mode === "compose" && composeKind === "article"
                        : exploreTab === t.id &&
                          (mode === "feed" ||
                            mode === "reader" ||
                            mode === "author")
                    }
                    onClick={() => openExploreTab(t.id)}
                  />
                ))}
              </>
            ) : null}

            {nav === "other" ? (
              <>
                <HubRow
                  title="联系反馈"
                  summary=""
                  action=""
                  active={otherTab === "support" && mode === "feed"}
                  onClick={() => {
                    leaveComposeThen(() => {
                      setOtherTab("support");
                      setMode("feed");
                      setNav("other");
                      setSideOpen(false);
                    });
                  }}
                />
                <HubRow
                  title="关于我们"
                  summary=""
                  action=""
                  active={otherTab === "about" && mode === "feed"}
                  onClick={() => {
                    leaveComposeThen(() => {
                      setOtherTab("about");
                      setMode("feed");
                      setNav("other");
                      setSideOpen(false);
                    });
                  }}
                />
              </>
            ) : null}
          </div>
        </div>
      </aside>

'''

text = text[:start] + new_block + text[end:]

# Remove mobile-tabs blocks in main-head (explore/other tabs now in sidebar)
old_tabs = '''          {narrow && nav === "explore" && mode !== "compose" ? (
            <div className="mobile-tabs" role="tablist">
              {EXPLORE_TABS.filter((t) => t.id !== "publish").map((t) => (
                <button
                  key={t.id}
                  type="button"
                  role="tab"
                  className={`mobile-tab${exploreTab === t.id && mode === "feed" ? " active" : ""}`}
                  onClick={() => openExploreTab(t.id)}
                >
                  {t.label.replace(/的文章$/, "").replace(/与回复$/, "")}
                </button>
              ))}
            </div>
          ) : null}
          {narrow && nav === "other" && mode !== "auth" && mode !== "settings" ? (
            <div className="mobile-tabs" role="tablist">
              <button
                type="button"
                role="tab"
                className={`mobile-tab${otherTab === "support" ? " active" : ""}`}
                onClick={() => {
                  setOtherTab("support");
                  setMode("feed");
                }}
              >
                联系反馈
              </button>
              <button
                type="button"
                role="tab"
                className={`mobile-tab${otherTab === "about" ? " active" : ""}`}
                onClick={() => {
                  setOtherTab("about");
                  setMode("feed");
                }}
              >
                关于我们
              </button>
            </div>
          ) : null}
'''
if old_tabs in text:
    text = text.replace(old_tabs, "")
else:
    print("WARN: mobile-tabs block not found")

# Fix any leftover railOpen/setRailOpen
text = text.replace("railOpen", "sideOpen")
# Careful: AppHeader still uses prop name railOpen — restore those
text = text.replace(
    """        sideOpen={sideOpen}
        onToggleRail={() => setSideOpen((v) => !v)}""",
    """        railOpen={sideOpen}
        onToggleRail={() => setSideOpen((v) => !v)}""",
)

path.write_text(text, encoding="utf-8")
print("patched ok, length", len(text))
