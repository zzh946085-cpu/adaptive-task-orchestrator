# Reasoning Evaluation Contract

## Scope

Use this contract to test routing and map safety without claiming that structural checks measure mathematical or coding intelligence.

The evaluation has three layers:

1. **Routing:** recompute the difficulty level and expected map behavior from observable case fields.
2. **Map safety:** validate syntax, bridge structure, target discipline, rejected branches, and hypothesis evidence paths.
3. **Instruction coverage:** compare whether a skill version contains the mechanisms needed to run layers 1 and 2.

Independent model forward-tests remain necessary for answer-quality claims. Do not infer answer correctness from a passing map.

## Routing contract

Score `reasoning_depth`, `ambiguity`, `execution_span`, `risk`, and `context_load` from 0 to 2 and cap the total at 10.

Map behavior is separate from task-ledger activation:

| Condition | Expected map behavior | Maximum prime depth |
|---|---|---:|
| Reasoning relation is not material | `none` | 0 |
| Level 0 with no material multi-step relation | `none` | 0 |
| Explicit scaffold request or a low-difficulty material multi-step relation | `compact` | 1 |
| Level 1 math, code, or causal relation with several dependent steps | `single` | 1 |
| Competing hypotheses, or a level 2 proof, diagnosis, or architecture decision | `dual` | 2 |
| Level 2 reasoning outside those classes | `single` | 1 |
| Level 3 with material reasoning | `dual-persist` | 3 |

`dual-persist` means use a dual map during work but retain only the bridge, decisions, material rejected branches, and next action in persistent state.

## Map safety contract

Treat these as invalid:

- missing context or goal anchor;
- missing branch parent, undeclared node, cycle, or absent dual bridge;
- a target used as a forward premise;
- a rejected node used in an active relation;
- an unsupported mode value.

Emit a semantic warning when:

- a hypothesis reaches a target without passing through evidence;
- an unknown is used as a forward premise;
- solve mode has no unknown node;
- diagnose mode has no falsifiable hypothesis;
- proof mode has no lemma, transformation, or evidence node.

Use `scripts/reasoning-eval.ps1` for the bundled regression corpus. Review corpus labels when routing policy changes; do not silently rewrite expected outcomes to make a failing implementation pass.
