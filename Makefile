export PATH := $(shell pwd)/cryptic-buildkite-plugin/bin:$(PATH)

decrypt:
	cd .buildkite/cryptic_repo_root && decrypt --repo-root=$$(pwd) --verbose

sign_treehashes:
	cd .buildkite/cryptic_repo_root && sign_treehashes --repo-root=$$(pwd) --verbose
	git commit -a -m "sign treehashes"

verify_treehashes:
	cd .buildkite/cryptic_repo_root && verify_treehashes --repo-root=$$(pwd) --verbose

print-%:
	echo "$*=$($*)"
