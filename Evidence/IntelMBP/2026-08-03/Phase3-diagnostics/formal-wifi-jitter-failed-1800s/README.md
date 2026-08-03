# Phase 3 failed live diagnostic

This is a real 30-minute Hermes relay run from the Intel MacBook Pro to the
4096x2304 Mac mini. It is retained as failed diagnostic evidence and must not be
represented as Phase 3 acceptance evidence.

The hardware H265 -> NV12 IOSurface -> Metal path remained active with bounded
decoder and renderer queues, but the run failed the 4K performance gate at
25.40 encoded FPS, 21.26 presented FPS and a 0.837 presented/encoded ratio.
Connection credentials and endpoint identifiers are not recorded.
