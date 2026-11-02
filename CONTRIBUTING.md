# Contributing

## Product promises

Tests protect behavior that a user can observe. For git-sight those promises include finding repositories and abandoned work, reporting their state accurately, and never modifying a repository.

A test must answer four questions before it is added or changed:

1. What product behavior or independent contract does it protect?
2. What credible regression makes it fail?
3. Why does the existing proof miss that regression?
4. Can it use a real production boundary without a test-only hook?

Do not add assertion-free probes, self-comparisons, source greps, copied inventories, implementation call-shape checks, or mocks that supply the behavior being asserted.

## Red, green, proof

Work in small commits:

1. **Red:** add a focused failing test. Confirm that it fails for the intended reason and commit it with `test: … (red)`.
2. **Green:** make the smallest complete production change that passes the test.
3. **Mutation proof:** change one relevant production behavior in an isolated copy. The mutant must compile and the new test must fail. Restore the source and rerun the unmodified suite. Record the mutation and the test that killed it in the green commit message.

A new or changed test is not accepted until it kills at least one valid mutant. A mutant that does not compile is invalid, not killed. If a mutant survives, improve the test before committing the implementation.

Use targeted, agent-run mutation checks for each test. Run Muter on core logic after substantial milestones and before releases; a full run is deliberately not a per-commit gate. Mutation score is diagnostic, not a target. Investigate survivors and document any truly equivalent mutant instead of weakening a test to chase a number.

## Adversarial review

A significant change gets a review by an agent with fresh context. Give that agent the product promise, the diff, and the test evidence. Its job is to falsify the change: find broken behavior, missing boundaries, unsafe repository operations, and tests that cannot catch a credible regression.

Review is required when any of these apply:

- the change can affect read-only safety, user data, security, or concurrency;
- it introduces a product contract, architectural boundary, or dependency;
- it changes more than 200 net lines or five production files.

Routine copy edits, formatting, mechanical renames, and small isolated fixes with regression proof do not need a separate adversarial review. Size does not exempt a risky change.

## Checks

Run the tests and relevant focused checks before every green commit. Run `git diff --check` before committing. Keep build artifacts and mutation reports out of version control.
