export PATH := $(shell pwd)/cryptic-buildkite-plugin/bin:$(PATH)

.PHONY: decrypt
decrypt:
	cd .buildkite/cryptic_repo_root && decrypt --repo-root=$$(pwd) --verbose

.PHONY: nocommit_sign_treehashes
nocommit_sign_treehashes:
	cd .buildkite/cryptic_repo_root && sign_treehashes --repo-root=$$(pwd) --verbose

.PHONY: sign_treehashes
sign_treehashes: nocommit_sign_treehashes
	git commit -a -m "sign treehashes"

.PHONY: verify_treehashes
verify_treehashes:
	cd .buildkite/cryptic_repo_root && verify_treehashes --repo-root=$$(pwd) --verbose
