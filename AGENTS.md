# 协作约定（给所有 agent）

## 改代码前先开 worktree

**在这个仓库里写任何代码之前，先开一个自己的 git worktree，不要在共用的主工作树上改。**

多个 agent 并行开发，主工作树是共用的：写文件会撞上别人的在途编辑，
提交时也容易把别人的在途工作一起卷进去。

```bash
cd /Users/edenzou/workspace/shepaw/shepaw
# 然后调用 EnterWorktree
```

`worktree.baseRef` 已设成 `head`——这个仓库**没有 remote**，默认的 `fresh` 会失败。

注意这个仓库是作为 gitlink 挂在外层 `shepaw` 仓库里的，**没有 `.gitmodules`**，
所以在外层开 worktree 时它的行为取决于外层配置；改 App 代码就直接在这里开。

确实要在主树改：设 `SHEPAW_MAIN_TREE_OK=1`。`.claude/` 和 `CLAUDE.md`/`AGENTS.md` 是豁免的。
