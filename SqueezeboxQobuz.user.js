// ==UserScript==
// @id             SqueezeBoxQobuz
// @name           SqueezeBoxQobuz
// @version        1.0-02
//
// @match http://www.qobuz.com/*/album/*
// @match http://www.qobuz.com/*/telechargement-album-mp3/*
// @include http://www.qobuz.com/*/album/*
// @include http://www.qobuz.com/*/telechargement-album-mp3/*
//
// Pierre Beck 11/2012	Creation
// Pierre Beck 11/2014	Modification to match qobuz change on their pages architecture
// drEagle 07/2015 Modification pour ajout de boutons Queue & Play
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

var albumIdentifier = document.querySelector("#item > div.action > span.btnLike").getAttribute("data-item-id");
var divListen = document.querySelector("#buyIt > div.actListen");

var newA = document.createElement("a");
newA.href="#";
var newB = document.createElement("b");
newB.href="#";

var language = window.navigator.language.substr(0,2);
switch (language) {
	case "fr":
		newA.innerHTML = "Jouer avec la SqueezeBox";
		break;
	default:
		newA.innerHTML = "Play with the SqueezeBox";
		break;
}

var language = window.navigator.language.substr(0,2);
switch (language) {
	case "fr":
		newB.innerHTML = "Ajouter à la SqueezeBox";
		break;
	default:
		newB.innerHTML = "Add to SqueezeBox";
		break;
}

newA.className = "btn btn-green"
newB.className = "btn btn-green"

newA.onclick = function(){
	var iframe = document.createElement("iframe");
	iframe.style.display = "none";
	iframe.src = "http://" + squeezeBoxServer + "/status.html?p0=qobuz&p1=playalbum&p2=" + albumIdentifier + multiPlayerSuffix + multiPlayerAuth;
	this.parentNode.appendChild(iframe);
	return false;
};

newB.onclick = function(){
	var iframe = document.createElement("iframe");
	iframe.style.display = "none";
	iframe.src = "http://" + squeezeBoxServer + "/status.html?p0=qobuz&p1=addalbum&p2=" + albumIdentifier + multiPlayerSuffix + multiPlayerAuth;
	this.parentNode.appendChild(iframe);
	return false;
};

divListen.appendChild(newA);
divListen.appendChild(newB);
