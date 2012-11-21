#!/bin/sh

if [ -e Qobuz ]; then
	rm -rf Qobuz/*
else
	mkdir Qobuz
fi

cp * Qobuz/ &> /dev/null
cp -R HTML Qobuz/
rm -f Qobuz/*.zip Qobuz/*.sh*

VERSION=`grep -o -E "version>(.*)</ver" install.xml | grep -o -E "[0-9]\.[0-9]+"`

ZIPFILE=Qobuz-$VERSION.zip

zip -9vr $ZIPFILE Qobuz -x *.sh* *.zip

rm -rf Qobuz/

shasum $ZIPFILE