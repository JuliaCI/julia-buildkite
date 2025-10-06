# Steps to do every time Julia does a feature freeze

These steps need to be performed every time Julia does a feature freeze. For this document, we'll use as an example the new minor version `1.2345`.

Table of contents:

1. Create the new branch in this repo (the `JuliaCI/julia-buildkite` repo), and start using it
2. Create the new Buildkite "pipeline" named `julia-release-1.2345`

## 1. Create the new branch in this repo (the `JuliaCI/julia-buildkite` repo), and start using it

1. Create a new branch in **this repo** (the `JuliaCI/julia-buildkite` repo) named `release-julia-1.2345`.
2. Make a PR to the `JuliaLang/julia` repo to edit the [`.buildkite-external-version` file](https://github.com/JuliaLang/julia/blob/master/.buildkite-external-version), to change the contents from `main` to `release-julia-1.2345`. Until that PR is merged, Buildkite won't actually be using the `release-julia-1.2345` branch in this repo.

## 2. Create the new Buildkite "pipeline" named `julia-release-1.2345`

1. Go to https://buildkite.com/julialang
2. In the top-right-hand corner, click on the white "New Pipeline" button.
3. You are now on a page that says "New Pipeline". Fill in the fields as follows:
    - Name: `julia-release-1.2345`
    - Description: `https://github.com/JuliaLang/julia`
    - Git Repository:
        - Step i. Click on the dropdown that says "Any account", and click on `JuliaLang`.
        - Step ii: Click on the text field that says `git@github.com:your/repo.git, and from the dropdown menu that appears, click on `JuliaLang/julia`.
        - Step iii: Next to "Checkout using", click on the radio button for `HTTPS`. Once you do that, the URL should automatically change to `https://github.com/JuliaLang/julia.git`
    - Auto-create webhooks: make sure that this checkbox IS checked.
    - Teams: select the following two teams:
        - `[ALL USERS] Base Julia CI (build and read)`
        - `Base Julia CI (Slack notifications)`
4. At the bottom of the page, click on the green "Create Pipeline" button.
5. Go to https://buildkite.com/julialang/julia-release-1-dot-2345 and click on the white "Edit steps" button.
6. Delete ALL text in the text box.
7. Into the text box, paste the exact contents from the folllowing file: https://github.com/JuliaCI/julia-buildkite/blob/main/pipelines/main/0_webui.yml
8. Click on the white "Save Steps" button.
9. Go to https://buildkite.com/julialang/julia-release-1-dot-2345 and click on the white "Pipeline Settings" (or just "Settings") button in the top-right-hand corner.
10. In the left-hand side, under "Pipeline Settings", click on "General". Then, scroll down to the bottom of the page. In the "Pipeline Management" section, click on the white "Make Pipeline Public" button. If you are asked for confirmation, click on the green "Make Pipeline Public" button to confirm your decision.
11. Go to https://buildkite.com/julialang/julia-release-1-dot-2345 and click on the white "Pipeline Settings" (or just "Settings") button in the top-right-hand corner.
12. In the left-hand side, under "Pipeline Settings", click on "Builds". Then, in the "Build Skipping" section, do the following actions:
    - Step i: Make sure that the "Skip Intermediate Builds" checkbox IS checked.
    - Step ii: Make sure that the "Cancel Intermediate Builds" checkbox IS checked.
    - Step iii: Under "Skip Intermediate Builds", in the text box, enter the following text: `!master !main !release-*`
    - Step iv: Under "Cancel Intermediate Builds", in the text box, enter the following text: `!master !main !release-*`
    - Step v: Click on the green "Save Build Skipping" button.
13. Go to https://buildkite.com/julialang/julia-release-1-dot-2345 and click on the white "Pipeline Settings" (or just "Settings") button in the top-right-hand corner.
14. In the left-hand side, under "Pipeline Settings", click on "GitHub". Then, in the "Branch Limiting" section, do the following actions:
    - Step i: For "Branch Filter Pattern", enter the following text: `release-1.2345 v1.2345.*`
    - Step ii: Click on the green "Save Branch Limiting" button.
15. You are still on the "Pipeline Settings ⟶ GitHub" page. In the "GitHub Settings" section, do the following actions:
    - Step i: Make sure that the radio button for "Trigger builds after pushing code" IS selected.
    - Step ii: Make sure that the checkbox for "Filter after pushing code" IS selected.
    - Step iii: Under "Filter builds using a conditional", enter the following text: `(build.pull_request.base_branch == null) || (build.pull_request.base_branch == "release-1.2345") || (build.pull_request.base_branch == "backports-release-1.2345")`
    - Step iv: Make sure that the checkbox for "Build Pull Requests" IS selected.
    - Step v: Under "Build Pull Requests", make sure that the checkbox for "Build pull requests from third-party forked repositories" IS selected.
    - **Step vi: Under "Build pull requests from third-party forked repositories", make sure that the checkbox for "Prefix third-party fork branch names" IS selected. It's important to make sure you complete this step.**
    - Step vii: Make sure that the checkbox for "Build tags" IS selected.
    - Step viii: Make sure that the checkbox for "Cancel deleted branch builds" IS selected.
    - Step ix: Make sure that the checkbox for "Update commit statuses" IS selected.
    - Step x: Under "Update commit statuses", for "Show blocked builds in GitHub as", from the drop-down menu, select "Pending".
    - Step xi: Make sure that the checkbox for "Create a status for each job" is NOT selected.
    - Step xii: Make sure that the checkbox for "Separate statuses for pull requests" is NOT selected.
    - Step xiii: At the bottom of the page, click on the green "Save GitHub Settings" button.
16. Go to https://buildkite.com/julialang/julia-release-1-dot-2345 and click on the white "Pipeline Settings" button.
17. In the left-hand side, under "Pipeline Settings", click on "Teams". Then do the following actions:
    - Step i: Next to "Base Julia CI (Slack notifications)", click on the text `Full Access` and change it to `Read Only`.
    - Step ii: Next to "[ALL USERS] Base Julia CI (build & read)", click on the text `Full Access` and change it to `Build & Read`.


