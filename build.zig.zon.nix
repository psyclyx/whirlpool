# Zig package dependencies for Whirlpool. Keep each entry's name identical to
# the package hash in build.zig.zon; `zig build --system` resolves by that
# content-addressed directory name without network access.
{
  fetchgit,
  fetchzip,
  linkFarm,
}:
linkFarm "whirlpool-zig-packages" [
  {
    name = "wayland-0.7.0-dev-lQa1kl38AQC-kQolS5D4jV1GJ2rH2jv1VWHr14YLVnyn";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/zig-wayland";
      rev = "23839e41161de025d71ce082561ecba1c5331281";
      hash = "sha256-6iehxkESzs7BvKnKlq0XqAYzO2lnl4tdiksaKfuKDhA=";
    };
  }
  {
    name = "snail-0.17.0-vw75SNx0BAFzdp060Ml4RA5dOUlWLslg9XkuGk6B6oi_";
    path = fetchzip {
      url = "https://github.com/psyclyx/snail/archive/refs/tags/v0.17.0.tar.gz";
      hash = "sha256-1bqXrpODgU1X5z2KiPyH1v+ZtGsDoMR+krgiz9CF+lk=";
    };
  }
]
