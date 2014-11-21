// ==UserScript==
// @match http://www.qobuz.com/*/album/*
// @match http://www.qobuz.com/*/telechargement-album-mp3/*
// @include http://www.qobuz.com/*/album/*
// @include http://www.qobuz.com/*/telechargement-album-mp3/*
//
// Pierre Beck 11/2012	Creation
// Pierre Beck 11/2014	Modification to match qobuz change on their pages architecture
//
// needs SqueezeboxQobuz plugin v1.70+
// http://forums.slimdevices.com/showthread.php?97146-Qobuz-com-streaming-plugin
// https://github.com/pierrepoulpe/SqueezeboxQobuz/downloads
//
// ==/UserScript==

alert("Edit SqueezeboxQobuz.user.js before using it!"); return; // delete this line, uncomment and edit the next ones
const squeezeBoxServer = "192.168.0.19:9000";
const multiPlayerSuffix = ""; //"&player=04:00:20:12:45:AB"
const multiPlayerAuth = ""; //&cauth=xxxxxx" 

var albumIdentifier = document.querySelector("#info > div.action > span.btnLike").getAttribute("data-item-id");
var divListen = document.querySelector("#buyIt > div.actListen");

var newA = document.createElement("a");
newA.href="#";

var language = window.navigator.language.substr(0,2);
switch (language) {
case "fr":
	newA.innerHTML = "avec la SqueezeBox";	break;
default:
	newA.innerHTML = "with the SqueezeBox";	break;
}

newA.className = "btn btn-green"

newA.onclick = function(){
	var iframe = document.createElement("iframe");
	iframe.style.display = "none";
	iframe.src = "http://" + squeezeBoxServer + "/status.html?p0=qobuz&p1=playalbum&p2=" + albumIdentifier + multiPlayerSuffix + multiPlayerAuth;
	this.parentNode.appendChild(iframe);
	return false;
};

divListen.appendChild(newA);
