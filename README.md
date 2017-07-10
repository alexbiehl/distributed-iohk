# How to build distributed-iohk

Invoke

```bash
$ cabal new-build
```

to build `distributed-iohk`. You can find the generated binary in
`dist-newstyle/build/x86_64-osx/ghc-8.0.2/distributed-iohk-0.1.0.0/c/distributed-iohk/build/distributed-iohk/distributed-iohk`.

Please be aware that dependencies are frozen with `cabal.project.freeze` as well
as the compiler version is bound to `ghc-8.0.2`. To relax these constrains delte
`cabal.project.freeze` and edit `cabal.project`.

# How to invoke distributed-iohk

``` bash
$ distributed-iohk --help
Usage: distributed-iohk [--send-for SECONDS] [--wait-for SECONDS]
                        [--with-seed INT] [--host HOST] [--port PORT]

Available options:
  -h,--help                Show this help text
```

  * Default host is "127.0.0.1"
  * Default port is 8081
  * Default send-for is 20 seconds
  * Default wait-for is 10 seconds

# How to configure the cluster nodes

There is constant `nodeAddresses` in `Main.hs` which is a list of hostname and
port of all available nodes in the cluster. The following `nodeAddresses`
declares a cluster on localhost:


``` haskell
nodeAddresses :: [(Host, Port)]
nodeAddresses =
  [ ("127.0.0.1", 8081)
  , ("127.0.0.1", 8082)
  , ("127.0.0.1", 8083)
  , ("127.0.0.1", 8084)
  ]
```

When invoking `distributed-iohk` make sure to choose `--host` and `--port`
parameters which are present in `nodeAddresses`.

# Communication model

`distributed-iohk` broadcasts its messages in a fire-and-forget manner. Since
every emitted float is accompanied by a sequence number (starting from 1) we can
easily determine which messages have been dropped. In the current model we
maintain total order over the messages by storing every single one. This may not
be suitable to a real world scenario as this would ideally require unlimited
resources. Since we know which messages have been dropped we could reach out to
other nodes and ask for the missing ones.
