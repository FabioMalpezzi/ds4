You are validating DS4's own self-improvement loop with both native Git and
context/KV tools.

Do not explain the plan in prose. Use DSML tools.

Repository root: __REPO__
Ledger path: __LEDGER__

Task:
Fix the small Python project in the repository so its test suite passes. The
bug is intentionally simple and local to the repository.

Use absolute file paths under the repository root for read, edit, write, and
bash commands. Use the git tool's repo parameter for Git inspection.

Required sequence:

1. Use the context tool with action=checkpoint and label
   self-improvement-before. This context checkpoint call must be the only tool
   call in its DSML block. Save the returned checkpoint id for step 8.

2. Use the git tool with action=status and repo set to the repository root.

3. Use read/edit/write/bash tools as needed to inspect, fix, and test the
   project. Run exactly this test command with the bash tool:

cd __REPO__ && python3 test_toy_math.py

4. Use the git tool with action=diff, repo set to the repository root, and path
   set to toy_math.py to inspect the produced change.

5. If the test passes, use the context tool with action=checkpoint and label
   self-improvement-after-pass. This context checkpoint call must be the only
   tool call in its DSML block. Save the returned checkpoint id for step 6.

6. Use the context tool with action=restore, id set to the checkpoint id from
   step 5, reason=self-improvement-restore-check, and
   allow_side_effect_mismatch=true. This context restore call must be the only
   tool call in its DSML block.

7. After restore, use the git tool with action=status and repo set to the
   repository root. Then run exactly this test command again with the bash tool:

cd __REPO__ && python3 test_toy_math.py

   After this restore, do not create any more context checkpoints and do not
   call context restore again. Proceed directly to the ledger.

8. Use the write tool to create the ledger file at the ledger path. The ledger
   must contain these exact field names:

# DS4 Self Improvement Ledger
git_status_used=yes
git_diff_used=yes
context_checkpoint_before=yes
context_checkpoint_after=yes
context_restore_used=yes
tests_before_restore=pass
tests_after_restore=pass
fixed_file=toy_math.py
final=SELF_IMPROVEMENT_DONE

9. After the write tool result, answer exactly:
SELF_IMPROVEMENT_DONE
