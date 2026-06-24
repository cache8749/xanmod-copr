 rpmbuild -bb  --define "debug_package %{nil}" --define "_sourcedir $(pwd)"  kernel.spec
