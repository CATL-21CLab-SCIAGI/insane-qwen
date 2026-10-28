"""Offline scanner boundary. Never imported by the web or inference service."""
def main():
    from . import _scan, _rank
    output = _scan.main()
    if output is not None: _rank.rank(output)

if __name__ == '__main__': main()
