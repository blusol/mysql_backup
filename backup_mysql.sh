#!/bin/bash


####	backup_mysql.sh - Faz backup das bases MySQL
#
#	Site..: http://NAOTENHO
#	Autor.: Ricardo Felipe Klein <klein@klein.inf.br>
#
#---------------------------------------------------------------------
#
#	Descobre automaticamente as bases presentes e faz backup das mesmas
#
#---------------------------------------------------------------------
#
# Historico:
#
#       v1.0 2012-04-20, autor: Ricardo Felipe Klein
#			- Versao inicial.
#
#       v1.1 2012-05-03, autor: Ricardo Felipe Klein
#			- Adicionado funcao para efetuar o dump das
#				functions e triggers.
#
#		v1.2 2012-07-10, autor: Ricardo Felipe Klein
#			- Alterado nome do arquivo para que fique organizado
#			  por data quando usuario efetuar ls no diretorio.
#			- Corrigido problema que fazia com que a montagem do 
#			  diretorio remoto falhasse em certas condicoes.
#			- Adicionado ultimas linhas do log a saida padrao de erro,
#			  se o script estiver agendado no cron esta parte dos logs
#			  vai junto com o email de aviso de erro.
#
#		v2.0 2013-11-26, autor: Ricardo Felipe Klein
#			- Chamadas de funcao refeitas para promover error handling.
#			- Removidas funcoes de NFS e mount (talvez voltem no futuro).
#			- Alterada forma de input dos parametros para um arquivo de configuracao.
#			- Cria arquivos separados para: SCHEMA, DADOS, TRIGERS/FUNCTIONS/STOREDPROCEDURES
#
#
#---------------------------------------------------------------------
#
# ToDo:
#
#	- Reinserir as funcoes de montagem de NFS e/ou outros tipo de fs?
#	- Checar o tamanho do backup anterior e o atual para ver se nao diminuiu e gerar algum warning
#
#---------------------------------------------------------------------
#
#	Depende de:
#		bash
#		cp
#		cron (para agendamento)
#		tar
#		bzip2 / xz / lzma / 7zip
#		mysqldump
#		nfs client (caso seja utilizada a funcao de montagem NFS)
#		mutt (send emails)
#
#		Usuario do banco de dados com as pemissoes:
#			GRANT SUPER, SELECT, LOCK TABLES ON *.* TO 'dump'@'%'
#---------------------------------------------------------------------
#
#	Exemplo de config file:
#		#!/bin/bash
#
#		DEBUG="no"
#		PID_FILE="/var/run/$(basename $0).pid"
#		LOG_FILE="/var/log/$(basename $0).log"
#		BACKUP_DIR="/mnt/backup"
#		DB_PARAMS="-u root --password=somepass -h 127.0.0.1 "
#		TEMPO_RETENCAO="43200"  # em minutos
#		EMAIL_ALERTS_SEND_TO="someone@domain.tldp"
#		

#
# VARIAVEIS
#
YEAR=$(date +%Y)
MONTH=$(date +%m)
DAY=$(date +%d)
HOUR=$(date +%H)
MINUTE=$(date +%M)

CONFIG_FILE="$1"
if [ -n $CONFIG_FILE ] && [ -e $CONFIG_FILE ] && [ -s $CONFIG_FILE ]
then
	. $CONFIG_FILE
else
	echo "Arquivo de configuracao invalido"
	echo "Executar da seguinte forma:"
	echo "      sh /path/to/backup_mysql.sh /path/to/configfile.cnf"
	exit 1
fi


#
# FUNCOES
#
## Escreve dados no log
f_escreveLog() {
	echo -ne "$(date) - BACKUP MySQL - $YEAR$MONTH$DAY-$HOUR - $1 \n" >> $LOG_FILE
}

## Checa se nao ha nenhum processo ativo
f_checaPid() {
	if [ -e $PID_FILE ]
	then
		f_escreveLog "ERROR - outro processo ja em execucao"
		echo "ERROR - outro processo ja em execucao"
		exit 1
	fi
}

## Cria o arquivo de pid e joga o PID nele
f_criaPid() {
	echo "$$" > $PID_FILE
}

## Remove o arquivo de PID
f_removePid() {
	alias rm="rm"
	rm -fr $PID_FILE
}

## Remove backups mais antigos que $TEMPO_RETENCAO
f_removeBackupAntigo() {
	alias rm="rm"
	find $BACKUP_DIR -name *.xz  -cmin +$TEMPO_RETENCAO -exec rm -rf '{}' \;
	find $BACKUP_DIR -name *.sql -cmin +$TEMPO_RETENCAO -exec rm -rf '{}' \;
	alias rm="rm -i"
}

## Executa o backup das bases
f_executaBackup() {
	DATABASES=$(mysql $DB_PARAMS --batch --skip-column-names -e "show databases;" | grep -v "information_schema" | grep -v "test" | grep -v "performance_schema")

	for BASE in $DATABASES
	do
		f_escreveLog "INFO  - Efetuando backup da base: $BASE"
		mysqldump $DB_PARAMS --set-charset --force --allow-keywords --max_allowed_packet=120M -K --hex-blob --routines=FALSE --triggers=FALSE --no-create-db $BASE > $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-data.sql
		xz -zf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-data.sql
		\rm -rf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-data.sql
		f_escreveLog "INFO  - Gerado o arquivo: $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-data.sql.xz"
		mysqldump $DB_PARAMS --set-charset --force --allow-keywords --max_allowed_packet=120M --no-data --routines --triggers --no-create-db --no-create-info -K --hex-blob $BASE > $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-functionsANDtriggers.sql
		xz -zf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-functionsANDtriggers.sql
		\rm -rf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-functionsANDtriggers.sql
		f_escreveLog "INFO  - Gerado o arquivo: $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-functionsANDtriggers.sql.xz"
		mysqldump $DB_PARAMS --set-charset --force --allow-keywords --max_allowed_packet=120M -K --hex-blob --routines=FALSE --triggers=FALSE --no-data $BASE > $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-schema.sql
		xz -zf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-schema.sql
		\rm -rf $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-schema.sql
		f_escreveLog "INFO  - Gerado o arquivo: $BACKUP_DIR/$YEAR$MONTH$DAY-$HOUR-$BASE-schema.sql.xz"
	done
}

f_errorHandling() {
	# mandaemail
	echo -ne "
		Houve um erro na execucao do backup_mysql.sh em $HOSTNAME\n
		DATA: $YEAR$MONTH$DAY-$HOUR:$MINUTE\n
		\n
		ULTIMAS 50 LINHAS DO LOG: \n

		$(tail -50 $LOG_FILE)


	"	| mutt -s "ERRO NO BACKUP_MYSQL.SH EM $HOSTNAME"  -b $EMAIL_ALERTS_SEND_TO

	echo "MANDAMOS EMAIL PARA $EMAIL_ALERTS_SEND_TO AVISANDO SOBRE O ERRO"
	f_escreveLog "MANDAMOS EMAIL PARA $EMAIL_ALERTS_SEND_TO AVISANDO SOBRE O ERRO"
}


#
# EXECUCAO
#
FUNCOES_EXECUTAR="	f_checaPid								 			\
					f_criaPid							 				\
					f_removeBackupAntigo								\
					f_executaBackup										\
					f_removePid											\
					"
for F_EXECUTA in $FUNCOES_EXECUTAR
do
	(set -e 
		$F_EXECUTA
	); RC=$?
	if [ $RC != 0 ]; then
		echo "ERROR: $RC"
		f_errorHandling
		exit 1
	fi
done

# DEBUG
if [ "$DEBUG" = "yes" ]
then
	cat $CONFIG_FILE
fi
