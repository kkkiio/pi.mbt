# github_issues_codemode

Example of using `codemode` with a custom `github_list_issues` tool to count and group open GitHub issues.

## Run

Requires `gh` (authenticated with GitHub) and a DeepSeek API key (`DEEPSEEK_API_KEY`, `.env`, or `~/.pim/auth.json`):

```bash
moon run --target js examples/github_issues_codemode
```

## Output

```text
- user: Count all open issues (excluding pull requests) in https://github.com/earendil-works/pi and group them by label name (sorted by count descending, plus an `(unlabeled)` count for issues with no labels). Also report total open issues.

- assistant:
    - thinking: We need fetch issues page by page using github_list_issues. Need count excluding PRs, group by label. Need know repo owner earendil-works, repo pi. Use codemode. Need paginate until less 100. Let's script.
    - tool_call: codemode
      code: |-
        const owner = "earendil-works";
        const repo = "pi";
        let page = 1;
        let issues = [];
        while (true) {
          const batch = await tools.github_list_issues({ owner, repo, page });
          issues.push(...batch);
          if (batch.length < 100) break;
          page++;
        }
        const openIssues = issues.filter(i => !i.pull_request);
        const counts = {};
        let unlabeled = 0;
        for (const issue of openIssues) {
          const labels = Array.isArray(issue.labels) ? issue.labels : [];
          if (labels.length === 0) unlabeled++;
          for (const label of labels) {
            const name = typeof label === "string" ? label : label.name;
            counts[name] = (counts[name] || 0) + 1;
          }
        }
        const grouped = Object.entries(counts).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
        return {
          pagesFetched: page,
          totalFetched: issues.length,
          totalOpenIssuesExcludingPRs: openIssues.length,
          grouped,
          unlabeled
        };

- tool_result: codemode
  calls:
    - github_list_issues({"owner":"earendil-works","repo":"pi","page":1}) -> ok
    - github_list_issues({"owner":"earendil-works","repo":"pi","page":2}) -> ok
    - github_list_issues({"owner":"earendil-works","repo":"pi","page":3}) -> ok
  output: |-
    Script completed
    Wall time 4.6 seconds
    Output:

    {"pagesFetched":3,"totalFetched":258,"totalOpenIssuesExcludingPRs":231,"grouped":[["bug",47],["inprogress",15],["durable",12],["mcp",8],["codemode",7],["last-read",7],["prio:p0",4],["possibly-openclaw-clanker",2],["to-discuss",2],["fix-available",1],["new-harness",1],["pkg:agent",1],["pkg:coding-agent",1]],"unlabeled":138}

- assistant:
    - text: |-
        **Total open issues (excluding pull requests): 231**

        The GitHub API returned 258 open entries across 3 pages, of which 27 were pull requests.

        | Label | Count |
        |---|---:|
        | bug | 47 |
        | inprogress | 15 |
        | durable | 12 |
        | mcp | 8 |
        | codemode | 7 |
        | last-read | 7 |
        | prio:p0 | 4 |
        | possibly-openclaw-clanker | 2 |
        | to-discuss | 2 |
        | fix-available | 1 |
        | new-harness | 1 |
        | pkg:agent | 1 |
        | pkg:coding-agent | 1 |
        | **(unlabeled)** | **138** |

        Label counts can sum to more than 231 because issues may have multiple labels.
```
