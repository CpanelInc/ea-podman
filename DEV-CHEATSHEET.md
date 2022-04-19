# EA4 Container Based Pkgs Cheatsheet

## What criteria should be met by images we do EA4 packages for?

1. There should be a good demand for it.
   * KiM one offs can be done using arbitrary images directly w/ `es-podman`
2. They must be trusted, so unless there is a very good reason not to:
   1. use images from https://hub.docker.com/
   2. use “Official Image” and/or “Verified Publisher”
3. They must be easy to package consistently:
   1. Pick a tag that is the version `{major}.{minor}.{build}` like `1.2.3` w/ no letters or other characters.
      - this makes them simple/consistent/clear to maintain, auto update, and use for end users
   2. Name the package `ea-{docker-hub-name}{major}{minor}`
      - e.g. https://hub.docker.com/_/mongo tag/version `5.0.6` would be `ea-mongo50`

Item 3, for example, makes it so `find-latest-version` can use the docker hub version finder.

## The minimum every package needs

**Note**: Some of this will be automated for us via ZC-9760.

The package’s git repo needs a `SOURCES/pkg.prerm` (used in the specfile’s `%preun` w/ `%include %{SOURCE<N>}`.

In `/opt/cpanel/<PKG>/` these files must exist.

1. `pkg-version` — a file with the software’s version
   * as its first and only line w/ no trailing newline
   * in our Mongo example above it’d be `5.0.6`
   * the spec file (and debify version generated from that) should create it so the version is always correct without needing maually edited
2. `ea-podman.json`
   ```
   {
      "ports" : [],
      "image" : "docker.io/library/{docker-hub-name}:{major}.{minor}.{build}",
      "startup" : {
          "<flag>" : [ "value1", "value2", "…" ],
      }
   }
   ```
   * the spec file (and debify version generated from that) should create it so the version is always correct without needing maually edited
   * Should explictly use `"ports" : [],` on images we won’t be using ports for.
3. `README.md` — a file explaining what they need to know about this image
   * this will be symlinked to in each container’s directory and used in `ea-podman avail`

There can be more, see [the DEDIGN doc](DESIGN.md) for details.
