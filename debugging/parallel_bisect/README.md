# parallel_bisect.jl

Our bootstrap process is single-threaded and slow.
When bisecting an issue, it sure would be nice if we could make use of all of those extra cores, wouldn't it?

```
julia -t5 --project parallel_bisect.jl <good_sha> <bad_sha> script_to_test_issue.jl
```

Build errors get skipped.
The first run will verify your script on the given good and bad gitsha's to ensure that it reacts properly.
Use the `-t` argument to Julia to specify how many jobs should run (each job will use enuogh threads to hopefully saturate your machine without completely destroying it).
