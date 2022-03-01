sign_treehashes:
	cd .buildkite/cryptic_repo_root && sign_treehashes --repo-root=$$(pwd) --verbose

verify_treehashes:
	cd .buildkite/cryptic_repo_root && verify_treehashes --repo-root=$$(pwd) --verbose
