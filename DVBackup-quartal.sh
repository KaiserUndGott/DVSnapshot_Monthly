#!/bin/bash




# Sichert monatlich bzw. quartalsweise rsanpshots.
# 
# Als root (via cron) ausfuehren. Script erfordert einen Aufrufparameter:
# "monthly" oder "quarterly".
#
# Die Montassicherung wird erst angelegt, sobald hinreichend Tagessicherungen
# vorliegen (siehe hierzu rsnapshot.spng.conf). Entsprechendes gilt für die 
# Quartalssicherungen.
# Beispiel: Sind 28 Tagessicherungen konfiguriert, wandelt rsnapshot.monthly
# das Verzeichnis daily.27 in das Verzeichnis monthly.0 um. Existiert (noch)
# kein daily.27, wird auch keine Montassicherung angelegt.
#
# SPnG (FW), Stand: Mai 2015; Version 0.99





# zum Anpassen ################################################################

# Dieses Protokoll wird abschliessend als Mail versandt:
LOG="/tmp/rsync_autobackup.log"

# Lokaler Empfaenger der Protokoll Mail:
MAIL="david@localhost"

# Config Datei fuer rsnapshot (Achtung: Spezialversion!):
config="/etc/rsnapshot.spng.conf"

# Deviceangabe der Snapshot Partition:
snap="/dev/sdc1"

# #############################################################################




JETZT=`date +%c` && echo $JETZT >$LOG



# Pruefung auf Rootrechte:
echo ""
if [ ! "`id -u`" -eq "0" ]; then
   echo "ABBRUCH, keine Rootrechte :-("
   echo ""
   exit 1
fi


# config fuer rsnapshot korrekt angegeben?
if   [ ! -e $config ]; then
     text1="$config nicht gefunden."
elif [[ `cat $config | grep Speedpoint` = "" ]]; then
     text2="Die Datei muss den Ausdruck \"Speedpoint\" enthalten."
     echo "$text1 $text2" | mail -s "WARNUNG: Backup nicht korrekt konfiguriert!" $MAIL
     echo"ABBRUCH: $config nicht korrekt bzw. nicht gefunden :-(" | tee -a $LOG
     echo ""
     exit 1
fi


# Korrekter Parameter uebergeben?
if [ "$#" -ne 1 ];then
	echo "ABBRUCH: Ungueltige Anzahl Parameter uebergeben :-(" | tee -a $LOG
	echo ""
	exit 1	
fi


# Umrechnung, da rsnapshot bei 0 zu zaehlen beginnt:
TAG=`cat $config | grep daily   | awk {'print $3'}` && TAGSNAP=`expr $TAG - 1`
MON=`cat $config | grep monthly | awk {'print $3'}` && MONSNAP=`expr $MON - 1`
TYP=$1


# Mountpoint fuer die Snapshots testen:
check="0"
grep $snap /etc/fstab >/dev/null
CHECK=`echo $?`
if [ "${CHECK}" != "0" ] ; then
	text="Sicherungsfestplatte $snap nicht in fstab gefunden."
	echo $text
	echo $text | mail -s "WARNUNG: Backup nicht korrekt konfiguriert!" $user@localhost
	echo ""
	exit 1
else
	echo "Snapshot Medium ist $snap."
	MPOINT=`grep $snap /etc/fstab | awk {'print $2'}`
	FEHLER="0"
	FSCKGO="yes"
fi


mount $snap && sleep 1
#
# Sind die Voraussetzungen fuer Montas- oder Quartalssicherungen erfuellt?
case $TYP in
	  monthly)	INT="monthly"
			SNAPTYP="Monatliche"
			if [ ! -d $MPOINT/daily.$TAGSNAP ]; then
				echo "Abbruch ohne Montassicherung (es sind noch keine $TAG Tagessicherungen vorhanden)." | tee -a $LOG
				umount $snap || echo "Fehler beim Aushaengen von $snap." | tee -a $LOG
				echo ""
				exit 0
			else
				echo "$MPOINT/daily.$TAGSNAP vorhanden."
			fi
			;;
	quarterly)	INT="quarterly"
			SNAPTYP="Quartalsweise"
			TEST2=`find $MPOINT -type d -name monthly.$MONSNAP`
			if [ "${TEST2}" = "" ]; then
				echo "Abbruch ohne Quartalssicherung (es sind noch keine $MON Monatssicherungen vorhanden)." | tee -a $LOG
				umount $snap || echo "Fehler beim Aushaengen von $snap." | tee -a $LOG
				echo ""
				exit 0
			fi
			;;
	  	*)	echo "ABBRUCH: Ungueltiger Parameter uebergeben :-(" | tee -a $LOG
			echo ""
			exit 1
			;;
esac


# Ist die Snapshot Partition fehlerfrei?
umount $snap >/dev/null 2>&1
sleep 1
mount | grep $snap && FEHLER="1"
# Falls umount scheitert, greifen vermutlich noch Prozesse auf das device zu:
if [ "${FEHLER}" = "1" ] ; then 
	echo "Folgende Prozesse greifen derzeit auf $snap zu. Kill wird versucht."
	lsof $snap
	kill -9 `lsof -t $snap` >/dev/null 2>&1 || echo "Kill gescheitert."
	umount $snap >/dev/null 2>&1 && sleep 1 || umount -l $snap >/dev/null 2>&1
	mount | grep $snap
	CHECK=`echo $?`
	if [ "${CHECK}" = "0" ]; then
		fscheck="fsck wird gestartet."   
	else
		fscheck="fsck wird nicht gestartet, da umount von $snap fehlschlug."
		FSCKGO="no"
	fi
	echo $fscheck 
else
	# fsck ggf. starten:
	if [ "${FSCKGO}" = "yes" ]; then
		e2fsck -n $snap | grep 'sauber' >/dev/null
		CHECK=`echo $?`
		if [ "${CHECK}" = "0" ]; then
			sauber="true"
			echo "Das Dateisystem von $snap ist sauber."
		else
			text="WARNUNG: Das Dateisystem von $snap muss repariert werden, bitte umgehend Speedpoint anrufen."
			echo $text | mail -s "Die Sicherungsfestlatte ist offenbar fehlerhaft und muss geprueft werden." $user@localhost
			echo $text
			echo ""
			#exit 1
		fi
	fi
fi


# ISAM anhalten
JETZT=`date +%c` && echo $JETZT >>$LOG
cd /home/david
./iquit
if [ `ps ax | grep isam | wc -l` -lt 3 ]; then
   echo "ISAM beendet." | tee -a $LOG
else
   echo "Fehler beim Beenden des ISAM Dienstes." | tee -a $LOG
fi


# Sicherung starten
mount $snap && sleep 1
echo "Datensicherung laeuft..." | tee -a $LOG
# ======================================
rsnapshot -v -c $config $INT >>$LOG 2>&1
CHECK=`echo $?`
# ======================================
if [ "${CHECK}" = "0" ] ; then
   echo "-> rsnapshot $INT erfolgreich." | tee -a $LOG
else
   echo "!! rsnapshot $INT mit Fehler(n) beendet." | tee -a $LOG
fi


# ISAM starten
cd /home/david && ./isam
if [ `echo $?` == 0 ]; then
   echo "ISAM Dienst laeuft." | tee -a $LOG
else
   echo "Fehler beim ISAM Start." | tee -a $LOG
fi


# Logdatei abschliessen und senden
echo "-------------------------------"
echo "Backup beendet, bitte $LOG bzw. Mail an $MAIL beachten."
JETZT=`date +%c` && echo $JETZT >>$LOG
echo "$SNAPTYP DATA VITAL Sicherung beendet, Details siehe Anhang." | mail -s "DV Monatssicherung" -a $LOG $MAIL


umount $snap
exit 0

