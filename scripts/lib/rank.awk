# Ranking and trust (DESIGN section 7.2).
#
# Input (via -v): nodes (node_table output), verifs (verify_table output),
#                 dir (higher|lower), noise (threshold), noise_mode (absolute|relative:
#                 the threshold is a fraction of the recorded score).
# Output: node_table columns 1-14, then
#   15 trust            verified | unverified | suspect | inherits_suspect | failed | invalid
#   16 effective_score  empty if none
#   17 n_verify         valid reproductions by other agents
#   18 children         valid child nodes
#   19 verify_scores    comma-separated reproduced scores ("failed" for failed reproductions)

function abs(x) { return x < 0 ? -x : x }

function median(list,    a, n, i, j, t) {
  n = split(list, a, ",")
  for (i = 2; i <= n; i++) { t = a[i] + 0; for (j = i - 1; j >= 1 && a[j] + 0 > t; j--) a[j + 1] = a[j]; a[j + 1] = t }
  if (n % 2) return a[(n + 1) / 2] + 0
  return (a[n / 2] + a[n / 2 + 1]) / 2
}

function mean_with(score, list,    a, n, i, s) {
  n = split(list, a, ","); s = score + 0
  for (i = 1; i <= n; i++) s += a[i]
  return s / (n + 1)
}

# has_suspect_ancestor(id): any ancestor (through all parents) is suspect.
function has_suspect_ancestor(id,    ps, n, i, p) {
  if (id in memo) return memo[id]
  memo[id] = 0
  n = split(parents[id], ps, ",")
  for (i = 1; i <= n; i++) {
    p = ps[i]
    if (!(p in trust)) continue
    if (trust[p] == "suspect" || has_suspect_ancestor(p)) { memo[id] = 1; break }
  }
  return memo[id]
}

BEGIN {
  FS = "\t"
  n = split(nodes, lines, "\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] == "") continue
    split(lines[i], f, "\t")
    id = f[1]; order[++count] = id; row[id] = lines[i]
    parents[id] = f[3]; score[id] = f[4]; status[id] = f[5]; aid[id] = f[6]; problem[id] = f[13]
  }
  m = split(verifs, vl, "\n")
  for (i = 1; i <= m; i++) {
    if (vl[i] == "") continue
    split(vl[i], v, "\t")
    node = v[1]
    if (v[6] != "" || !(node in row) || v[2] == aid[node]) continue
    if (v[4] == "ok") { oks[node] = (node in oks ? oks[node] "," : "") v[3]; nver[node]++ }
    else { fails[node]++; nver[node]++ }
    shown[node] = (node in shown ? shown[node] "," : "") (v[4] == "ok" ? v[3] : "failed")
  }
  for (k = 1; k <= count; k++) {
    id = order[k]
    if (problem[id] != "") { trust[id] = "invalid"; eff[id] = ""; continue }
    if (status[id] == "failed") { trust[id] = "failed"; eff[id] = ""; continue }
    if (!(id in nver)) { trust[id] = "unverified"; eff[id] = score[id]; continue }
    if (!(id in oks)) { trust[id] = "suspect"; eff[id] = ""; continue }
    med = median(oks[id])
    tol = (noise_mode == "relative") ? noise * abs(score[id]) : noise + 0
    if (abs(med - score[id]) > tol || (id in fails)) { trust[id] = "suspect"; eff[id] = sprintf("%.6g", med) }
    else { trust[id] = "verified"; eff[id] = sprintf("%.6g", mean_with(score[id], oks[id])) }
  }
  for (k = 1; k <= count; k++) {
    id = order[k]
    if (trust[id] == "unverified" && has_suspect_ancestor(id)) trust[id] = "inherits_suspect"
    if (trust[id] == "invalid") continue
    np = split(parents[id], ps, ",")
    for (j = 1; j <= np; j++) children[ps[j]]++
  }
  for (k = 1; k <= count; k++) {
    id = order[k]
    printf "%s\t%s\t%s\t%d\t%d\t%s\n", row[id], trust[id], eff[id], nver[id] + 0, children[id] + 0, shown[id]
  }
}
