use strict;
use utf8;
use WWW::Mechanize;
use Data::Dumper;
use JSON::Parse 'parse_json';
use XML::Simple;
use IO::Socket::SSL;
use URI::Escape;
use Encode;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $user_agent = 'Mozilla/5.0 (Windows; U; Windows NT 6.1; nl; rv:1.9.2.13) Gecko/20101203 Firefox/3.6.13';

my $form_name = 'MARIA DA SILVA';
my $form_cpf = '889.895.960-50';
(my $form_cpf_numbers_only = $form_cpf) =~ s/[^0-9]//g;

my $min_value_pensionista = 30000;
my $min_value_inativo = 40000;
my $min_value_ativo = 50000;

my $nofetch = 0;

sub dump_entry {
	my ($name, $cargo, $value, $fonte, $aposentado, $ano, $mes) = @_;

	my $date = sprintf "%02d/%04d", $mes, $ano;

	$name =~ s/\s{2,}/ /;
	$cargo =~ s/\s+$//;

	if ($cargo =~ /^PENS/) {
		if ($value > $min_value_pensionista) {
			print "$name\t$cargo - $fonte\t$value\t$date\n";
		}
	} elsif ($aposentado) {
		if ($value > $min_value_inativo) {
			if (defined $cargo) {
				print "$name\t$cargo - APOSENTADO - $fonte\t$value\t$date\n";
			} else {
				print "$name\tAPOSENTADO - $fonte\t$value\t$date\n";
			}
		}
	} else {
		if ($value > $min_value_ativo) {
			print "$name\t$cargo - $fonte\t$value\t$date\n";
		}
	}
}

sub convert_to_csv {
	my $filename = shift;
	print STDERR "converting $filename to csv...\n";
	`soffice --headless --convert-to csv:"Text - txt - csv (StarCalc):59,ANSI,1" $filename`;
}

sub pdf_as_html {
	my $filename = shift;

	my $filename_html = "$filename-html.html";

	if (!-e $filename_html) {
		print STDERR "converting $filename to html...\n";
		system 'pdftohtml', '-c', '-s', '-i', '-q', $filename;
		die if !-e $filename_html;
	}

	return $filename_html;
}


#
#   T R T - 1
#

sub fetch_trt1 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt1-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = 'http://www.trt1.jus.br/anexo-viii';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $content = $bot->content;

		my $nome_mes = qw(Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro)[$mes - 1];
		die unless $content =~ /strong>$ano.*?href="(\/c\/document_library\/[^"]*)"[^>]*>(<[^>]*>){0,3}$nome_mes/;

		my $pdf_url = $1;
		print STDERR "url: $pdf_url\n";
		$bot->get($pdf_url, ':content_file' => $filename);

		print STDERR "done fetching\n";
	}

	return $filename;
}

sub filter_trt1 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt1($ano, $mes);

	open my $fh, "gunzip -c $filename | pdftotext -q -layout - - |" or die;
	binmode $fh, ':utf8';

	while (<$fh>) {
		chomp;
		my ($name, $where, $cargo, $value) = (split /  +/)[0, 1, 2, 8];

		next if $name =~ /^TOTAL/;

		# $cargo =~ s/ ?\([^\)]*\)//;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~/^APOSENTADO/;
		if ($where =~ /^PENSIONISTA/) {
			$cargo = 'PENSIONISTA';
		}

		dump_entry($name, $cargo, $value, 'TRT-1', $aposentado, $ano, $mes);
	}

	close $fh;
}

#
#   T R T - 2
#

sub fetch_trt2 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt2-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

=pod
		my $url = 'http://aplicacoes8.trtsp.jus.br/contaspublicas/consulta/7/2/0/0';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		$bot->submit_form(
			form_number => 1,
			fields => {
				'nome' => 'DILMA VANA ROUSSEFF',
				'doc_type' => 'cpf',
				'cpf' => '13326724691',
				'ddd' => '0',
				'telefone' => '0',
				'email' => 'x',
				'mes' => (sprintf "%02d", $mes),
				'ano' => $ano,
				'versao' => '01',
			});

		my $r = $bot->response;
		die $r->status_line unless $r->is_success;

		print STDERR $r->content_type;

		open my $fh, '>', $filename;
		binmode $fh;
		print $fh $r->content;
		close $fh;
=cut
		# lixo de form so' existe para logar e responder "arquivo existe"

		my $url = sprintf 'http://aplicacoes8.trtsp.jus.br/contaspublicas/documento/7/2/0/0/%02d/%04d/01', $mes, $ano;
		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url, ':content_file' => $filename);

		if ($bot->response->content_type eq 'text/html') {
			unlink $filename;
			die "PDF not available?"
		}
	}

	return $filename;
}

sub filter_trt2 {
	my ($ano, $mes) = @_;

	my $filename_html = pdf_as_html(fetch_trt2($ano, $mes));

	open my $fh, $filename_html;
	binmode $fh, ':utf8';

	local $/;
	my $data = <$fh>;
	close $fh;

	$data =~ /left:(\d+)px;[^>]*>.*?Nome/ or die;
	my $nome_x = $1;

	while ($data =~ /((<p [^>]*left:${nome_x}px;[^>]*>[^\n]*?<\/p>\s*)+)(<p [^>]*>[0-9,.]+<\/p>\s*){5}<p [^>]*>([0-9,.]+)/sgm) {
		my ($info, $value) = ($1, $4);

		$info =~ s/<[^>]*>//g;
		$info =~ s/&#160;/ /g;
		$info =~ s/[\r\n]//g;

		$info =~ /^([^-]*) \(/;
		my $name = $1;

		$info =~ /- ([^-]*)$/;
		my $cargo = $1;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $info =~ /INATIVO/;

		next if $cargo =~ /^POSTO /; # merda

		dump_entry($name, $cargo, $value, 'TRT-2', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 3
#

sub filter_trt3 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt3-%02d-%04d', $mes, $ano;
	die unless -e $filename; # run fetch_trt3.pl

	open my $fh, $filename or die;
	binmode $fh, 'encoding(ISO8859-1)';

	while (<$fh>) {
		my ($name, $where, $cargo, $value) = (split /\t/)[0, 1, 2, 9];

		$name = uc($name);
		$where = uc($where);
		$cargo = uc($cargo);

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /^INATIVO/;

		dump_entry($name, $cargo, $value, 'TRT-3', $aposentado, $ano, $mes);
	}

	close $fh;
}

#
#   T R T - 4
#

sub fetch_trt4 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt4-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = "https://www.trt4.jus.br/portais/trt4/estrutura-remuneratoria-folha";

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $nome_mes = qw(JANEIRO FEVEREIRO MARACO ABRIL MAIO JUNHO JULHO AGOSTO SETEMBRO OUTUBRO NOVEMBRO DEZEMBRO)[$mes - 1];
		$bot->follow_link(url_regex => qr/${nome_mes}([ _]|%20)${ano}\.csv/); # fuck this

		$bot->submit_form(
			form_number => 2,
			fields => {
				'nome' => $form_name,
				'cpf' => $form_cpf_numbers_only
			});

		my $r = $bot->response;
		die $r->status_line unless $r->is_success;

		die $r->content_type unless $r->content_type eq 'application/octet-stream' or $r->content_type eq 'application/vnd.ms-excel';

		open my $fh, '>', $filename;
		binmode $fh;
		print $fh $r->content;
		close $fh;
	}

	return $filename;
}

sub filter_trt4 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt4($ano, $mes);

	open my $fh, "gunzip -c $filename |" or die;

	while (<$fh>) {
		my ($name, $where, $cargo, $value) = ($_ =~ /"([^"]*)",?/g)[0, 1, 2, 9];

		$value =~ s/,/./;

		my $aposentado = $where =~ /^INATIVO/;

		dump_entry($name, $cargo, $value, 'TRT-4', $aposentado, $ano, $mes);
	}

	close $fh;
}

#
#   T R T - 5
#

sub fetch_trt5 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt5-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = "http://www.trt5.jus.br/folha-pagamento?field_data_transparencia_value%5Bvalue%5D%5Byear%5D=$ano";

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $content = $bot->content;
		die if $content !~ /a href="([^"]*)"><span class="date-display-single">0?$mes\/$ano/;

		my $pdf_url = $1;
		$bot->get($pdf_url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt5 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt5($ano, $mes);

	open my $fh, "gunzip -c $filename | pdftotext -q -layout - - |" or die;
	binmode $fh, ':utf8';

	my $date = sprintf "%02d/%04d", $mes, $ano;

	while (<$fh>) {
		next unless /^[A-Z]/;

		my ($name, $cargo, $value) = (split /  +/)[0, 2, 8];

		$name = uc($name);
		$cargo = uc($cargo);

		$cargo .= ' TRABALHO' if $cargo =~ /VARA DO$/;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		dump_entry($name, $cargo, $value, 'TRT-5', 0, $ano, $mes);
	}

	close $fh;
}

#
#   T R T - 6
#

sub fetch_trt6 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt6-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = 'http://apps.trt6.jus.br/rescnj102/index.php?boxaction=exibeConsultaRemuneracao';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $input = $bot->current_form()->find_input('formato');
		$input->{menu}->[1]->{disabled} = 0; # fuck you

		$bot->submit_form(
			form_number => 1,
			fields => {
				'nome' => $form_name,
				'tipoDocumento' => 'cpf',
				'numeroDocumento' => $form_cpf,
				'ano' => $ano,
				'mes' => $mes,
				'formato' => 'csv'
			});

		my $r = $bot->response;

		die $r->status_line unless $r->is_success;
		die unless $r->content_type eq 'text/csv';

		# my $filename = $r->filename;

		open my $fh, '>', $filename;
		binmode $fh;
		print $fh $r->content;
		close $fh;
	}

	return $filename;
}

sub filter_trt6 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt6($ano, $mes);

	open my $fh, '<', $filename or die;
	binmode $fh, ':utf8'; # hah

	local $/ = undef;
	my $data = <$fh>;
	close $fh;

	$data =~ s/\r\n//g; # fuck you

	my $date = sprintf "%02d/%04d", $mes, $ano;

	for ($data =~ /(.*)\n/g) {
		my ($name, $where, $cargo, $value) = ($_ =~ /([^;]*);?/g)[0, 1, 2, 8];

		$name =~ s/^.*?"\*?//;
		$name =~ s/"$//;
		$name =~ s/\s+/ /g;

		$where =~ s/^.*?"\*?//;
		$where =~ s/"$//;

		$cargo =~ s/^.*?"\*?//;
		$cargo =~ s/"$//;

		$value =~ s/,/./;

		my $aposentado = $where =~ /^APOSENTADO/;

		dump_entry($name, $cargo, $value, 'TRT-6', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 7
#

sub fetch_trt7 {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'trt7-%02d-%04d', $mes, $ano;
	my ($filename_ods, $filename_csv) = ("$filename_base.ods", "$filename_base.csv");

	if (!-e $filename_csv) {
		if (!-e $filename_ods) {
			die if $nofetch;

			print STDERR "fetching $filename_ods...\n";

			my $url = 'http://www.trt7.jus.br/index.php?option=com_chronoforms6&chronoform=visualizarFolhaPagamento';

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			$bot->get($url);

			$bot->submit_form(
				form_number => 2,
				fields => {
					'nome' => $form_name,
					'tipo_documento' => 'CPF',
					'documento' => $form_cpf,

				});

			$bot->follow_link(text => $ano);

			my $content = $bot->content;

			my $nome_mes = qw(janeiro fevereiro marco abril maio junho julho agosto setembro outubro novembro dezembro)[$mes - 1];

			my $ods_url;
			if ($content =~ /href="(\/files.*anexoviii_${ano}_${nome_mes}.ods)"/) {
				$ods_url = $1;
			} else {
				# BARNABE' FDP
				$content =~ /href="(\/files.*anexoviii_${nome_mes}_${ano}.ods)"/ or die;
				$ods_url = $1;
			}

=pod
	<a href=\"/files/transparencia/anexoVIII_res102_cnj/2017/anexoviii_2017_fevereiro.ods\" target=\"_blank\">Fevereiro (formato .ods, tamanho 191kB)</a></td>
=cut
			$bot->get($ods_url, ':content_file' => $filename_ods);
		}

		convert_to_csv($filename_ods);
		die if !-e $filename_csv;
	}

	return $filename_csv;
}

sub filter_trt7 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt7($ano, $mes);

	open my $fh, '<', $filename or die;

	while (<$fh>) {
		s/^;+//;

		next unless /^[A-Z]/;
		next if /^TOTAL/;

=pod
ADAUTO FERNANDES DE OLIVEIRA;APOSENTADO;JUIZ TRT CLASSISTA ;0,00;;0,00;;30.471,11;432,72;0,00;0,00;30.903,83;;-2.134,93;0,00;;0,00;0,00;-2.134,93;28.768,90;;0,00;0,00;
=cut
		my ($name, $where, $cargo, $value) = (split /;/)[0, 1, 2, 11];

		$cargo =~ s/ ?[\/-].*//;
		$cargo =~ s/ +$//;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /^APOSENTADO/;

		dump_entry($name, $cargo, $value, 'TRT-7', $aposentado, $ano, $mes);
	}

	close $fh;
}

#
#   T R T - 8
#

sub fetch_trt8 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt8-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = 'http://www.trt8.jus.br/index.php?option=com_content&view=article&id=2214&Itemid=594'; 

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $content = $bot->content;

		my $nome_mes = qw(janeiro fevereiro maro abril maio junho julho agosto setembro outubro novembro dezembro)[$mes - 1];
		die $content unless $content =~ /"([^"]+$ano\/[^"]+$nome_mes\.pdf)"/;

		my $pdf_url = $1;
		$bot->get($pdf_url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt8 {
	my ($ano, $mes) = @_;

	my $filename_html = pdf_as_html(fetch_trt8($ano, $mes));

	open my $fh, $filename_html;
	binmode $fh, ':utf8';

	local $/;
	my $data = <$fh>;
	close $fh;

	# while ($data =~ /<p .+?>([A-Z&#160;<br\/>]+?)<\/p>\n<p .+?>(.+?)<\/p>\n<p .*?>(.+?)<\/p>\n<p .+?>([0-9&#,;\-<\/b> ]+?)<\/p>/gm) { # WHY NOT WORK
	while ($data =~ /<p .+?>([A-Z&#160;<br\/>]+?)<\/p>\n<p .+?>(.+?)<\/p>\n<p .*?>(.+?)<\/p>\n<p .+?>(.+?)<\/p>/gm) {
		my ($nome, $where, $cargo, $creditos) = ($1, $2, $3, $4);

		$nome =~ s/\&#160;/ /g;
		$nome =~ s/<[^>]*>//g;

		$where =~ s/\&#160;/ /g;
		$where =~ s/<[^>]*>//g;

		$cargo =~ s/\&#160;/ /g;
		$cargo =~ s/<[^>]*>//g;
		$cargo = uc($cargo);

		$creditos =~ s/\&#160;/ /g;
		$creditos =~ s/<[^>]*>//g;

		my $value = (split /\s+/, $creditos)[6];
		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /^Aposentados/;

		dump_entry($nome, $cargo, $value, 'TRT-8', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 1 0
#

sub fetch_trt10 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt10-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $nome_mes = qw(JANEIRO FEVEREIRO MARÇO ABRIL MAIO JUNHO JULHO AGOSTO SETEMBRO OUTUBRO NOVEMBRO DEZEMBRO)[$mes - 1];

		my $url = 'https://www.trt10.jus.br/?mod=ponte.php&ori=ini&pag=contas_publicas&path=servicos/contas_publicas/gestao_pessoas/index.php';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $content = $bot->content;

		die unless $content =~ /Folha de Pagamento.*?href="([^"]*)"[^>]*>[^<]*$nome_mes\/$ano/sm;

		my $document_url = $1;
		print STDERR "url: $document_url\n";
		$bot->get($document_url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt10 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt10($ano, $mes);

	open my $fh, '<', $filename or die;

	local $/ = undef;
	my $data = <$fh>;
	close $fh;

	while ($data =~ /colspan=[35] rowspan=2>\s*<[^>]*>([^<]+).*?<font[^>]*>([^<]*).*?<font[^>]*>([^<]*)(.*?<font){7}[^>]*><b>([^<]*)/gsm) {
		my ($name, $cargo, $where, $value) = ($1, $2, $3, $5);

		$value =~ s/^\s+//;
		$value =~ s/\s+$//;
		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = 0;
		if ($cargo =~ /^APOSENTADO/) {
			$aposentado = 1;
			undef $cargo;
		}

		if ($cargo =~ /^PENS.O CIVIL/) {
			$cargo = 'PENSIONISTA';
		}

		dump_entry($name, $cargo, $value, 'TRT-10', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 1 1
#

sub fetch_trt11 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt11-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = 'https://portal.trt11.jus.br/index.php/transparencia/portal-da-transparencia/informacoes-sobre-pessoal/listar-resolucao102-7';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

=pod
<td class="td-Resolucao102.ANO" style="">2017</td>
<td class="td-Resolucao102.MES" style="">Abril</td>
<td class="td-Arquivo.ARQUIVO" style="font-size: 20px; text-align: center;"> <a href="/components/com_chronoforms5/chronoforms/uploads/Resolucao102/2017/20170512135735___portalrh.trt11.jus.br_csp_trt11_cnj_transparenciaCliente.pdf " target="_blank"> <span style="color:#4E4B4B;"> <i class="fa fa-file-text" aria-hidden="true"></i> </span></a></td></tr>
=cut

		my $content = $bot->content;

		my $nome_mes = qw(Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro)[$mes - 1];
		die unless $content =~ m/td-Resolucao102.ANO" style="">$ano<\/td>\n<td class="td-Resolucao102.MES" style="">$nome_mes<\/td>\n<td.*?href="([^"]+)"/;

		my $pdf_url = $1;
		$bot->get($pdf_url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt11 {
	my ($ano, $mes) = @_;

	my $filename_html = pdf_as_html(fetch_trt11($ano, $mes));

	open my $fh, $filename_html;
	binmode $fh, ':utf8';

	local $/ = undef;
	my $data = <$fh>;
	close $fh;

=pod
<p style="position:absolute;top:382px;left:82px;white-space:nowrap" class="ft16">ABILIO&#160;DE&#160;SOUSA&#160;<br/>MARINHO&#160;NERY</p>
<p style="position:absolute;top:382px;left:159px;white-space:nowrap" class="ft16">Gabinete&#160;Desdora.&#160;<br/>Valdenyra&#160;Farias&#160;Thomé</p>
<p style="position:absolute;top:377px;left:268px;white-space:nowrap" class="ft16">TECNICO&#160;JUDICIARIO&#160;-&#160;<br/>ADMINISTRATIVA&#160;/&#160;FC-<br/>05</p>
<p style="position:absolute;top:387px;left:368px;white-space:nowrap" class="ft12">9.903,69</p>
<p style="position:absolute;top:387px;left:426px;white-space:nowrap" class="ft12">604,24</p>
<p style="position:absolute;top:387px;left:478px;white-space:nowrap" class="ft12">2.232,38</p>
<p style="position:absolute;top:387px;left:530px;white-space:nowrap" class="ft12">1.314,00</p>
<p style="position:absolute;top:387px;left:586px;white-space:nowrap" class="ft12">0,00</p>
<p style="position:absolute;top:387px;left:637px;white-space:nowrap" class="ft12">0,00</p>
<p style="position:absolute;top:387px;left:693px;white-space:nowrap" class="ft12">14.054,31</p>
=cut

	while ($data =~ /<p .*?>([A-Z].*?)<\/p>\n<p .*?>(.*?)<\/p>\n<p .*?>(.*?)<\/p>\n(<p .*?>[0-9\.,]+<\/p>\n){6}<p .*?>([0-9\.,]+)<\/p>/gm) {
		my ($nome, $where, $cargo, $value) = ($1, $2, $3, $5);

		$nome =~ s/\&#160;/ /g;
		$nome =~ s/<br\/>/ /g;
		$nome =~ s/ +/ /g;

		$where =~ s/\&#160;/ /g;
		$where =~ s/<br\/>/ /g;
		$where =~ s/ +/ /g;

		$cargo =~ s/\&#160;/ /g;
		$cargo =~ s/<br\/>/ /g;
		$cargo =~ s/ +/ /g;
		$cargo = uc($cargo);

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = 0;

		if ($where =~ /^INATIVO/) {
			undef $cargo;
			$aposentado = 1;
		}

		if ($where =~ /^PENSIONIST/) {
			$cargo = 'PENSIONISTA';
		}

		# print "$nome\t$cargo\t$value\n";
		dump_entry($nome, $cargo, $value, 'TRT-11', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 1 2
#

sub fetch_trt12 {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'trt12-%02d-%04d', $mes, $ano;
	my ($filename_xls, $filename_csv) = ("$filename_base.xls", "$filename_base.csv");

	if (!-e $filename_csv) {
		if (!-e $filename_xls) {
			die if $nofetch;

			print STDERR "fetching $filename_xls...\n";

			my $ano_mes = sprintf "%04d-%02d", $ano, $mes;

			my $url = 'http://www.trt12.jus.br/portal/areas/seest/extranet/estatistica/resolucao_cnj_102_2009_ex_2017.jsp#REMUNERACA';

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			$bot->get($url);

			$bot->follow_link(url_regex => qr/AnexoVIII-${ano_mes}.*\.xls/);

			$bot->submit_form(
				form_number => 2,
				fields => {
					'tipodocumento' => 'cpf',
					'documento' => $form_cpf_numbers_only,
					'nome' => $form_name
				});

			my $r = $bot->response;
			die $r->status_line unless $r->is_success;

			die $r->content_type unless $r->content_type eq 'application/vnd.ms-excel';

			open my $fh, '>', $filename_xls;
			binmode $fh;
			print $fh $r->content;
			close $fh;
		}

		convert_to_csv($filename_xls);
		die if !-e $filename_csv;
	}

	return $filename_csv;
}

sub filter_trt12 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt12($ano, $mes);

	open my $fh, '<', $filename or die;

	while (<$fh>) {
		next if /^TOTAL/;

=pod
ABISAIR MACHADO DE SOUZA;REP. CLASSISTA;INATIVO;4,064.20;2,506.50;0.00;580.00;0.00;0.00;7,150.70;114.33;345.50;0.00;0.00;459.83;6,690.87;0.00;0.00
=cut
		my ($name, $cargo, $where, $value) = (split /;/)[0, 1, 2, 9];

		$value =~ s/,//g;

		my $aposentado = $where =~ /^INATIVO/;

		dump_entry($name, $cargo, $value, 'TRT-12', $aposentado, $ano, $mes);
	}

	close $fh;
}


#
#   T R T - 1 3
#

sub fetch_trt13 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt13-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

=pod
curl -X GET --header 'Accept: application/json' 'https://www.trt13.jus.br/transparenciars/api/anexoviii/anexoviii?mes=3&ano=2017'
=cut

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->add_header('Accept' => 'application/json');
		my $url = "https://www.trt13.jus.br/transparenciars/api/anexoviii/anexoviii?mes=${mes}&ano=${ano}";
		$bot->get($url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt13 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trt13($ano, $mes);

	open my $fh, "gunzip -c $filename |" or die;
	binmode $fh, ':utf8';

	local $/ = undef;
	my $json_data = <$fh>;
	close $fh;

	my $data = parse_json($json_data);

	for my $barnabes (@{$data->{listaAnexoviiiServidorMagistradoPensionista}}) {
		for my $barnabe (@{$barnabes->{listaAnexoviii}}) {
			my $name = $barnabe->{nome};
			my $value = $barnabe->{rendimentos}->{totalCreditos};
			my $cargo = $barnabe->{cargo};
			my $where = $barnabe->{lotacao};

			my $aposentado = $where =~ /^INATIVO/;
			$cargo = 'PENSIONISTA' if $where =~ /^PENSIONISTA/;

			dump_entry($name, $cargo, $value, 'TRT-13', $aposentado, $ano, $mes);
		}
	}
}

#
#   T R T - 1 4
#

sub fetch_trt14 {
	my ($ano, $mes) = @_;

	my @filenames;

	for my $type (qw(serv mag)) {
		my $filename = sprintf "trt14-%02d-%04d.$type", $mes, $ano;

		if (!-e $filename) {
			die if $nofetch;

			print STDERR "fetching $filename...\n";

			my $url = 'http://relatorio1.trt14.jus.br/reports/rwservlet';

			my $bot = WWW::Mechanize->new(agent => $user_agent);

			# Oracle Toolkit 2 for Motif

			$bot->post($url, {
					'P_ANO' => $ano,
					'P_MES' => $mes,
					# 'desformat' => 'pdf',
					'desformat' => 'xml', # muhahah
					'server' => 'rep_producao_101',
					'userid' => 'transparencia/123456@BDTRT14',
					'destype' => 'CACHE',
					'report' => "fp_rel_transparencia_lei_acesso_${type}.rdf"
				});

			my $r = $bot->response;

			die $r->content_type unless $r->content_type eq 'text/xml';

			open my $fh, '>', $filename;
			binmode $fh;
			print $fh $r->content;
			close $fh;
		}

		push @filenames, $filename;
	}

	return \@filenames;
}

sub filter_trt14 {
	my ($ano, $mes) = @_;

	my $filenames = fetch_trt14($ano, $mes);

	for my $filename (@{$filenames}) {
		my $data = XMLin($filename);

		for my $barnabe (@{$data->{LIST_G_NIVEL_ORGANOGRAMA}->{G_NIVEL_ORGANOGRAMA}}) {
			my $name = $barnabe->{NOME};
			my $cargo = $barnabe->{CARGO};
			my $value = $barnabe->{BRUTO};
			$value =~ s/,/\./;

			dump_entry($name, $cargo, $value, 'TRT-14', 0, $ano, $mes);
		}
	}
}

#
#   T R T - 1 5
#

sub fetch_trt15 {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'trt15-%02d-%04d', $mes, $ano;

	my @filenames = ( "${filename_base}.1", "${filename_base}.2" );

	if (!-e $filenames[0] or !-e $filenames[1]) {
		die if $nofetch;

		print STDERR "fetching $filename_base...\n";

		my $url = 'http://portal.trt15.jus.br/folha-de-pagamento';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		$bot->submit_form(
			form_number => 2,
			fields => {
				'_1_WAR_webformportlet_INSTANCE_O4BkwSIteSl6_field1' => $form_name,
				'_1_WAR_webformportlet_INSTANCE_O4BkwSIteSl6_field2' => 'CPF',
				'_1_WAR_webformportlet_INSTANCE_O4BkwSIteSl6_field3' => $form_cpf_numbers_only,

			});

		my $content = $bot->content;

		my $mes_ano = sprintf "%02d%04d", $mes, $ano;

		die unless $content =~ /"([^"]+\/SERVIDORES_${mes_ano}_[^"]+\.csv[^"]+)"/;
		my $url_0 = $1;

		die unless $content =~ /"([^"]+\/MAGISTRADOS_${mes_ano}_[^"]+\.csv[^"]+)"/;
		my $url_1 = $1;

		$bot->get($url_0, ':content_file' => $filenames[0]);
		$bot->get($url_1, ':content_file' => $filenames[1]);
	}

	return \@filenames;

=pod
...pan></p> <p> <span class="texto"><strong>Anexo VIII</strong></span> - Detalhamento da Folha de Pagamento de Pessoal</p> <ul> <li> 2017 <ul> <li> Setembro - Magistrados (<a href="/documents/10157/37528/MAGISTRADOS_092017_05102017_1537.pdf/4cacff49-93f1-4d8b-81bc-3d246e296cd1" target="_blank">PDF</a>/<a href="/documents/10157/37528/MAGISTRADOS_092017_05102017_1537.csv/8b1c27da-eda4-4a58-b852-f6d9842d1074" target="_blank">CSV</a>) - Servidores (<a href="/documents/10157/37528/SERVIDORES_092017_05102017_1537.pdf/6e30effc-54f4-4b71-b795-ee5107942f34" target="_blank">PDF</a>/<a href="/documents/10157/37528/SERVIDORES_092017_05102017_1537.csv/8443ed76-3683-49fa-bcdc-5d5116ddf74e" target="_blank">CSV</a>)</li> <li> Agosto - Magistrados (<a href="/documents/10157/37528/MAGISTRADOS_082017_15092017_1354.pdf/ff56f027-3eed-43f9-92b5-c03c5f440953" target="_blank">PDF</a>/<a href="/documents/10157/37528/MAGISTRADOS_082017_15092017_1354.csv/4e190b28-24b2-4031-8f2c-c79a3b63b932" target="_blank">CSV</a>) - Servidores (<a href="/documents/10157/37528/SERVIDORES_082017_12092017_1621.pdf/04d4b947-553a-4b95-a27c-6efa60b4e4b4" target="_blank">PDF</a>/<a href="/documents/10157/37528/SERVIDORES_082017_12092017_1621.csv/3719a6c8-111c-40e9-8b75-6f7afacd372c" target="_blank">CSV</a>)</li> <li> Julho - Magistrados (<a href="/documents/10157/37528/MAGISTRADOS_072017_14082017_1826.pdf/4adef30b-bac0-4cc3-98e0-d94abb0bbc7a" target="_blank">PDF</a>/<a href="/documents/10157/37528/MAGISTRADOS_072017_14082017_1826.csv/88b49f38-649b-47e0-a331-f3bc5860354e" target="_blank">CSV</a>) - Servidores (<a href="/documents/10157/37528/SERVIDORES_072017_14082017_1826.pdf/c64f7c86-e8d2-4789-b015-369ae9089ac4" target="_blank">PDF</a>/<
=cut
}

sub filter_trt15 {
	my ($ano, $mes) = @_;

	my $filenames = fetch_trt15($ano, $mes);

	for my $filename (@{$filenames}) {
		open my $fh, '<', $filename or die;

		while (<$fh>) {
			# MAS QUE FDP
			my $separator;
			if (/\t/) {
				$separator = '\t';
			} else {
				$separator = ';';
			}

			my ($name, $where, $cargo, $value) = (split $separator)[0, 1, 2, 9];

			my $aposentado = 0;
			if ($where =~ /INATIVO/) {
				$cargo =~ s/ INATIVO//;
				$aposentado = 1;
			}

			$value =~ s/\.//g;
			$value =~ s/,/./;

			dump_entry($name, $cargo, $value, 'TRT-15', $aposentado, $ano, $mes);
		}

		close $fh;
	}
}

sub filter_trt18
{
	my ($ano, $mes) = @_;

	# captcha... can't fetch

	my $filename = sprintf 'trt18-%02d-%04d', $mes, $ano;
	die if !-e $filename;

	my $filename_csv = "$filename.csv";
	if (!-e $filename_csv) {
		convert_to_csv($filename);
		die if !-e $filename_csv;
	}

	open my $fh, '<', $filename_csv or die;

	while (<$fh>) {
		chomp;
		my ($name, $where, $cargo, $value) = (split /;/)[1, 2, 3, 10];

		next unless $name =~ /^[A-Z]/;

		my $aposentado = $where =~ /^RESIDENCIA/;

		$value =~ s/,//g;

		dump_entry($name, $cargo, $value, 'TRT-18', $aposentado, $ano, $mes);
	}
}

sub fetch_trt19
{
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trt19-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $ano_mes = sprintf '%04d%02d', $ano, $mes;

		my $url = 'http://trt19.jus.br/portalTRT19/gestaoPessoas/controleAcessoFolhaPagamentos';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		my $content = $bot->content;

		die unless $content  =~ /"(http[^"]*TRANSPARENCIA_$ano_mes[^"]*\.pdf)"/;

		my $pdf_url = $1;
		$bot->get($pdf_url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trt19
{
	my ($ano, $mes) = @_;

	my $filename = fetch_trt19($ano, $mes);

	open my $fh, "pdftotext -q -layout $filename - |" or die;
	binmode $fh, ':utf8';

	local $/ = undef;
	my $data = <$fh>;
	close $fh;

	while ($data =~ /\n(.*)\n((.*)\s(([0-9\.,]+\s+){15}))(.*)/gm) {
		my ($line1, $line2, $cargo2, $numbers, $where) = ($1, $2, $3, $4, $6);

		next if $line1 =~ /TOTAL/ or $line2 =~ /TOTAL/;

		my $name = substr $line1, 0, 48;
		$name =~ s/^\s+//;
		$name =~ s/\s+$//;

		my $cargo1 = substr $line1, 50; 
		$cargo1 =~ s/^\s*([0-9]*)?\s*//;
		$cargo2 =~ s/\s+$//;
		$cargo2 =~ s/^\s+//;
		my $cargo = "$cargo1 $cargo2";

		my $value = (split /\s+/, $numbers)[6];
		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /APOSENTADO/;

		dump_entry($name, $cargo, $value, 'TRT-19', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 2 2
#

sub fetch_trt22
{
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'trt22-%02d-%04d', $mes, $ano;
	my ($filename_xls, $filename_csv) = ("$filename_base.xls", "$filename_base.csv");

	if (!-e $filename_csv) {
		if (!-e $filename_xls) {
			die if $nofetch;

			print STDERR "fetching $filename_xls...\n";

			my $url = 'http://www.trt22.jus.br/folhadepagamento/';

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			$bot->get($url);

			# ugly hack to get around the fact that HTML::Form->click doesn't add
			# the name of the button as form field. shitty JSF relies on it so
			# we can't simply use $bot->submit_form here

			my $form = $bot->current_form;

			$form->value('j_idt6:j_idt11', 'CPF');
			$form->value('j_idt6:inputNome', $form_name);
			$form->value('j_idt6:inputDocumento', $form_cpf_numbers_only);

			my $request = $form->click('j_idt6:btnEntrar');
			$request->add_content('&j_idt6:btnEntrar=');

			$bot->request($request);

			# this is just horrible

			$bot->field('j_idt6:selectFiltroAno_input', $ano);

			my $id = $mes - 1;
			$bot->click("j_idt6:tableArquivosPorAno:$id:j_idt45", 1, 2);

			my $r = $bot->response;
			die $r->status_line unless $r->is_success;

			print STDERR $r->content_type;

			open my $fh, '>', $filename_xls;
			binmode $fh;
			print $fh $r->content;
			close $fh;
		}

		convert_to_csv($filename_xls);
		die if !-e $filename_csv;
	}

	return $filename_csv;

=pod
	open my $fh, '<trt22-lista.html';
	
	local $/ = undef;
	my $html = <$fh>;
	close $fh;

	my $form = HTML::Form->parse($html, 'http://localhost');
	die Dumper $form;

	$form->value('j_idt6:selectFiltroAno_input', $ano);

	my $request = $form->click("j_idt6:tableArquivosPorAno:$mes:j_idt45", 1, 2);

	die $request->content;
=cut

	# 	$bot->post('http://www.trt22.jus.br/folhadepagamento/lista-downloads.xhtml', {
	# 		'j_idt6' => 'j_idt6',
	# 		'j_idt6:selectFiltroAno_focus' => '',
	# 		'j_idt6:selectFiltroAno_input' => 2017,
	# 		'j_idt6:tableArquivosPorAno:3:j_idt45.x' => 17,
	# 		'j_idt6:tableArquivosPorAno:3:j_idt45.y' => 14,
	# 		'javax.faces.ViewState' => $view_state,
	# 	});
	# 
	# 	my $r = $bot->response;
}

sub filter_trt22
{
	my ($ano, $mes) = @_;

	my $filename = fetch_trt22($ano, $mes);

	open my $fh, '<', $filename or die;

	while (<$fh>) {
		my ($name, $where, $cargo, $value) = (split /;/)[0, 1, 2, 9];

		$value =~ s/,//g;

		my $aposentado = 0;
		if ($cargo =~ /^INAT/) {
			$aposentado = 1;
			undef $cargo;
		}

		dump_entry($name, $cargo, $value, 'TRT-22', $aposentado, $ano, $mes);
	}
}

#
#   T R T - 2 4
#

sub fetch_trt24
{
	my ($ano, $mes) = @_;

	my $url = 'http://www.trt24.jus.br/contas_publicas/index.jsf';

	my $filename = sprintf 'trt24-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = "http://www.trt24.jus.br/arq/contasPublicas/srh/Detalhamento_da_folha_de_pagamento_${mes}_${ano}.pdf";

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url, ':content_file' => $filename);

		my $r = $bot->response;
		die $r->status_line unless $r->is_success;

		print STDERR $r->content_type;
	}

	return $filename;
}

sub filter_trt24
{
	my ($ano, $mes) = @_;

	my $filename_html = pdf_as_html(fetch_trt24($ano, $mes));

	open my $fh, $filename_html; binmode $fh, ':utf8';

	local $/;
	my $data = <$fh>;
	close $fh;

	# doesn't catch everything but maybe good enough

	while ($data =~ /<p [^>]*>([A-Z][^<]*)<\/p>\n<p [^>]*>([A-Z][^<]*)<\/p>\n<p [^>]*>([A-Z][^<]*)<\/p>\n(<p [^>]*>[()0-9.,&#;\- ]*<\/p>\n){11,12}<p [^>]*>([0-9.,]+)</gm) {
		my ($nome, $where, $cargo, $value) = ($1, $2, $3, $5);

		$nome =~ s/\&#160;/ /g;

		$where =~ s/\&#160;/ /g;

		$cargo =~ s/\&#160;/ /g;
		# $cargo =~ s/ [0-9.,]+$//;
		$cargo =~ s/ -.*$//;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /APOSENTADO/;

		dump_entry($nome, $cargo, $value, 'TRT-24', $aposentado, $ano, $mes);
	}
}

#
#   T S T
#

sub filter_tst {
	my ($ano, $mes) = @_;

	# captcha, have to fetch manually :(

	my $filename = sprintf "tst-%02d-%04d", $mes, $ano;

	open my $fh, "pdftotext -q -layout $filename - |" or die;
	binmode $fh, ':utf8';

	while (<$fh>) {
		chomp;
		next unless /^[A-Z]/;

		my ($name, $cargo, $where, $value) = (split /  +/)[0, 1, 2, 8];

		my $aposentado = $where =~ /^APOSENTADO/;

		next if $cargo =~ /^MINISTRO/ and not $aposentado; # meh

		$value =~ s/\.//g;
		$value =~ s/,/\./;

		dump_entry($name, $cargo, $value, 'TST', $aposentado, $ano, $mes);
	}

	close $fh;
}

#
#   T S E
#

sub filter_tse {
	my ($ano, $mes) = @_;

	# captcha, have to fetch manually :(

	my $filename = sprintf "tse-%02d-%04d", $mes, $ano;

	open my $fh, '<', $filename or die;
	binmode $fh, 'encoding(ISO8859-1)';

	local $/;
	my $data = <$fh>;
	close $fh;

	while ($data =~ /c01">([^<]+).*?c03 capitalize">([^<]+).*?c02">([^<]+).*?Total de cr.*?>([^<]+)/gsm) {
		my ($name, $where, $cargo, $value) = ($1, $2, $3, $4);

		$name = uc($name);
		$name =~ s/\s+$//;

		$cargo = uc($cargo);
		$cargo =~ s/\s+$//;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		# print "$name\t$cargo\t$value\n";

		my $aposentado = 0;

		if ($cargo =~ /^INATIVO/) {
			undef $cargo;
			$aposentado = 1;
		}

		$cargo = 'PENSIONISTA' if $cargo =~ /^PENS/;

		dump_entry($name, $cargo, $value, 'TSE', $aposentado, $ano, $mes);
	}
}

#
#   T R E - R J
#

sub fetch_trerj {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trerj-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = sprintf 'http://www.tre-rj.jus.br/site/transparencia/cnj/gestao_orcamentaria/jsp/anexo_oito_detalhamento.jsp?mes=%02d&ano=%04d', $mes, $ano;
		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url, ':content_file' => $filename);
	}

	return $filename;
}

sub filter_trerj {
	my ($ano, $mes) = @_;

	my $filename = fetch_trerj($ano, $mes);

	open my $fh, $filename;

	local $/ = '</tr>';
	while (my $record = <$fh>) {
		if ($record =~ /<tr[^>]*>\n<td[^>]*>([^<]*)<\/td>\n<td[^>]*>([^<]*)<\/td>\n<td[^>]*>([^<]*)<\/td>(.*\n){6}<td[^>]*>([^<]*)<\/td>/m) {
			my ($name, $where, $cargo, $value) = ($1, $2, $3, $5);

			next if $name =~ /^TOTAL/;

			$value =~ s/,//g;

			my $aposentado = $where =~ /^INATIVO/;

			dump_entry($name, $cargo, $value, 'TRE-RJ', $aposentado, $ano, $mes);
		}

=pod
		<tr>
		<td align='left'>ACACIO DOS SANTOS JUNIOR</td>
		<td align='left'>218ª ZE/MADUREIRA (MAE: 118ª ZE)</td>
		<td align='left'>TÉCNICO JUDICIÁRIO - C13</td>
		<td align='right'>   9,350.23</td>
		<td align='right'>     400.72</td>
		<td align='right'>   1,019.17</td>
		<td align='right'>   1,099.00</td>
		<td align='right'>        .00</td>
		<td align='right'>  11,869.12</td>
		<td align='right'>  -1,072.60</td>
		<td align='right'>  -1,745.32</td>
		<td align='right'>    -557.51</td>
		<td align='right'>        .00</td>
		<td align='right'>  -3,375.43</td>
		<td align='right'>   8,493.69</td>
		<td align='right'>        .00</td>
		<td align='right'>        .00</td>
		</tr>

=cut
	}
}

#
#   T R F - 1
#

sub fetch_trf1 {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'trf1-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		die if $nofetch;

		print STDERR "fetching $filename...\n";

		my $url = sprintf 'http://www.trf1.jus.br/Servicos/VerificaFolha/arquivos/2017/%02d_%04d.PDF', $mes, $ano;
		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url, ':content_file' => $filename);

		if ($bot->response->content_type ne 'application/pdf') {
			unlink $filename;
			die "PDF not available?";
		}
	}

	return $filename;
}

sub filter_trf1 {
	my ($ano, $mes) = @_;

	my $filename = fetch_trf1($ano, $mes);

	open my $fh, "pdftotext -q -layout $filename - |" or die;
	binmode $fh, ':utf8';

	local $/ = undef;
	my $data = <$fh>;
	close $fh;

	# this one really sucks

	while ($data =~ /^(.*?[^0-9]) {2,}([0-9.,\-]+ +){6}([0-9.,\-]+).*\n(.*)$/gm) {
		my ($line1, $value, $line2) = ($1, $3, $4);

		next if $line1 =~ /[a-z]/;

		$line2 =~ s/.*//;

		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $name1 = substr $line1, 0, 24;
		$name1 =~ s/^\s+//;
		$name1 =~ s/\s+$//;

		my $name2 = substr $line2, 0, 24;
		$name2 =~ s/^\s+//;
		$name2 =~ s/\s+$//;

		my $name = "$name1 $name2";

		my $cargo1 = substr $line1, 55;
		$cargo1 =~ s/^\s+//;
		$cargo1 =~ s/\s+$//;

		my $cargo2 = substr $line2, 55;
		$cargo2 =~ s/^\s+//;
		$cargo2 =~ s/\s+$//;

		my $cargo = "$cargo1 $cargo2";

		$cargo =~ s/\/.*//;

		my $aposentado = $line1 =~ /INATIVO/;

		dump_entry($name, $cargo, $value, 'TRF-1', $aposentado, $ano, $mes);
	}
}

sub filter_trf2 {
	my ($ano, $mes) = @_;

  	my @orgaos = ('TRF-2 - SEÇÃO JUDICIÁRIA DO RIO DE JANEIRO',
		      'TRF-2 - TRIBUNAL REGIONAL FEDERAL DA 2ª REGIÃO',
		      'TRF-2 - SEÇÃO JUDICIÁRIA DO ESPÍRITO SANTO');

	for my $orgao (1 .. 3) {
		my $fonte = $orgaos[$orgao - 1];
		
		my $filename = sprintf 'trf2-%d-%02d-%04d', $orgao, $mes, $ano;
		die if !-e $filename;

		open my $fh, $filename or die;
		binmode $fh, ':utf8';

		while (<$fh>) {
			chomp;

			my ($name, $cargo, $where, $value) = split /\t/;

			$value =~ s/\.//;
			$value =~ s/,/./;

			my $aposentado = $where =~ /^APOSENT/;
			$cargo = 'PENSIONISTA' if $where =~ /^PENSIONISTA/;

			dump_entry($name, $cargo, $value, $fonte, $aposentado, $ano, $mes);
		}

		close $fh;
	}
}

sub fetch_tjes {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'tjes-%02d-%04d', $mes, $ano;
	my ($filename_ods, $filename_csv) = ("$filename_base.ods", "$filename_base.csv");

	if (!-e $filename_csv) {
		if (!-e $filename_ods) {
			print STDERR "fetching $filename_ods...\n";

			my $url = 'http://www.tjes.jus.br/portal-da-transparencia/pessoal/folha-de-pagamento';

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			$bot->get($url);

			$bot->submit_form(
				form_number => 3,
				fields => {
					'nome' => $form_name,
					'cpf' => $form_cpf_numbers_only,
				});

			my $content = $bot->content;

			my $mes_ano = sprintf '%02d%04d', $mes, $ano;
			$content =~ /href="([^"]*${mes_ano}[^"]*ods)"/ or die;

			my $ods_url = $1;
			$bot->get($ods_url, ':content_file' => $filename_ods);
		}

		convert_to_csv($filename_ods);
		die if !-e $filename_csv;
	}

	return $filename_csv;
}

sub filter_tjes {
	my ($ano, $mes) = @_;

	my $filename = fetch_tjes($ano, $mes);

	open my $fh, '<', $filename or die;

	while (<$fh>) {
		chomp;
		my ($name, $where, $cargo, $value) = (split /;/)[2, 3, 4, 11];

		next unless $name =~ /^[A-Z]/;

		my $aposentado = $where =~ /INATIV/;

		$value =~ s/,//g;
		$cargo =~ s/^[0-9]* - //;
		$cargo =~ s/<[^>]*>.*$//;

		dump_entry($name, $cargo, $value, 'TJ-ES', $aposentado, $ano, $mes);
	}

	close $fh;
}

sub fetch_tjse {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'tjes-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		print STDERR "fetching $filename...\n";

		my $url = 'http://www.tjse.jus.br/csp/tjse/cnj/transparenciaClientes.csp';

		my $bot = WWW::Mechanize->new(agent => $user_agent);
		$bot->get($url);

		$bot->submit_form(
			fields => {
				'folhaMesId' => $mes,
				'folhaAno' => $ano,
			});

		my $r = $bot->response;
		die $r->status_line unless $r->is_success;

		open my $fh, '>', $filename;
		binmode $fh;
		print $fh $r->content;
		close $fh;
	}

	return $filename;
}

sub filter_tjse {
	my ($ano, $mes) = @_;

	my $filename = fetch_tjse($ano, $mes);

	open my $fh, "gunzip -c $filename |" or die;
	binmode $fh, ':utf8';

	local $/;
	my $data = <$fh>;
	close $fh;

	while ($data =~ /<tr>\s*<td[^>]*>([^<]*)<\/td>\s*<td[^>]*>([^<]*)<\/td>\s*<td[^>]*>([^<]*)<\/td>\s*(<td[^>]*>[^<]*<\/td>\s*){6}<td[^>]*>([^<]*)<\/td>\s*/gsm) {
		my ($name, $where, $cargo, $value) = ($1, $2, $3, $5);

		$value =~ s/\.//g;
		$value =~ s/,/./;

		$cargo = uc($cargo);
		my $aposentado = $cargo =~ /INATIVO/;

		dump_entry($name, $cargo, $value, 'TJ-SE', $aposentado, $ano, $mes);
	}
}

sub fetch_tjrr {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'tjrr-%02d-%04d', $mes, $ano;
	my ($filename_xls, $filename_csv) = ("$filename_base.xls", "$filename_base.csv");

	if (!-e $filename_csv) {
		if (!-e $filename_xls) {
			my $url = 'http://transparencia.tjrr.jus.br/index.php/downloads-diversos/viewcategory/165-remuneracoes-e-diarias-anexo-viii';

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			$bot->get($url);

			$bot->follow_link(url_regex => qr/ano-${ano}$/);

			my $nome_mes = qw(janeiro fevereiro marco abril maio junho julho agosto setembro outubro novembro dezembro)[$mes - 1];
			$bot->content =~ /href="([^"]*${nome_mes}-anexo-viii[^"]*)"><img[^>]*excel/ or die;

			my $xls_url = $1;
			print STDERR "url: $url\n";
			$bot->get($xls_url, ':content_file' => $filename_xls);
		}

		convert_to_csv($filename_xls);
		die if !-e $filename_csv;
	}

	return $filename_csv;
}

sub filter_tjrr {
	my ($ano, $mes) = @_;

	my $filename = fetch_tjrr($ano, $mes);

	open my $fh, '<', $filename or die;

	while (<$fh>) {
		my ($name, $cargo, $where, $value) = (split /;/)[0, 1, 2, 8];
		$value =~ s/,//g;
		my $aposentado = $cargo =~ /APOSENTADO/;
		dump_entry($name, $cargo, $value, 'TJ-RR', $aposentado, $ano, $mes);
	}

	close $fh;
}

sub add_request_values
{
	my ($request, $values) = @_;

	while (my ($key, $value) = each %{$values}) {
		$request->add_content('&' . uri_escape($key) . '=' . uri_escape($value));
	}
}

sub fetch_tjpe {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'tjpe-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		my $url = 'https://www.tjpe.jus.br/consultasalario/xhtml/manterConsultaSalario/geralConsultaSalario.xhtml';

		my $bot = WWW::Mechanize->new(agent => $user_agent, ssl_opts => { 'SSL_ca_file' => 'tjpe.pem' });
		$bot->get($url);

		my $form = ($bot->forms())[2];
		$form->value('j_id23:nomeUsuario', 'DILMA VANA ROUSSEFF');
		$form->value('j_id23:tipoDocumentoSelect', 1);
		$form->value('j_id23:inputNumeroDocumento', '133.267.246-91');
		my $request = $form->click('j_id23:j_id40');
		add_request_values($request, { 'j_id23:j_id40' => 'Continuar' });
		$bot->request($request);

		my $nome_mes = ('Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro')[$mes - 1];

		my $form = ($bot->forms())[2];
		$form->value('j_id22:j_id40comboboxField', $nome_mes);
		$form->value('j_id22:j_id40', $nome_mes);
		$form->value('j_id22:j_id53comboboxField', $ano);
		$form->value('j_id22:j_id53', $ano);
		my $request = $form->click('j_id22:j_id63');
		add_request_values($request, { 'j_id22:j_id63' => 'Pesquisar' });
		$bot->request($request);

		open my $fh, '>', $filename;
		binmode $fh;
		print $fh $bot->content;
		close $fh;
	}

	return $filename;
}

sub filter_tjpe {
	my ($ano, $mes) = @_;

	my $filename = fetch_tjpe($ano, $mes);

	open my $fh, $filename;
	binmode $fh, ':utf8';

	local $/;
	my $data = <$fh>;
	close $fh;

	while ($data =~ /j_id112">([^<]*)<\/td><[^>]*j_id114">([^<]*)<\/td><[^>]*j_id116">([^<]*)<\/td>.*?j_id130[^>]*>([^<]*)</g) {
		my ($name, $cargo, $where, $value) = ($1, $2, $3, $4);

		$value =~ s/^R\$ //;
		$value =~ s/\.//;
		$value =~ s/,/./;

		my $aposentado = $where =~ /^APOSENTAD/;

		print "$name\t$cargo\t$where\t$value\n";

		# dump_entry($name, $cargo, $value, 'TJ-PE', $aposentado, $ano, $mes);
	}
}

sub fetch_tjto {
	my ($ano, $mes) = @_;

	my $filename = sprintf 'tjto-%02d-%04d', $mes, $ano;

	if (!-e $filename) {
		print STDERR "fetching $filename...\n";

		my $bot = WWW::Mechanize->new(agent => $user_agent);

		open my $fh, '>', $filename or die;
		binmode $fh, ':utf8';

		my $page = 1;

		while (1) {
			my $url = "https://gestaodepessoas.tjto.jus.br/site/transparencia/detalhamento_folha?utf8=%E2%9C%93&page=$page&tipo_relatorio=html&format=xls&transparencia_tb_detalhamento_folha%5Bano%5D=$ano&transparencia_tb_detalhamento_folha%5Bmes%5D=$mes&transparencia_tb_detalhamento_folha%5Bcdg_ordem%5D=&transparencia_tb_detalhamento_folha%5Bnm_cargo%5D=&transparencia_tb_detalhamento_folha%5Bnm_cargoext%5D=&transparencia_tb_detalhamento_folha%5Bcdg_unidade%5D=&button=";
			$bot->get($url);

			my $data = XMLin($bot->content);

			my $rows = $data->{Worksheet}->{Table}->{Row};

			last if not ref($rows) eq 'ARRAY';

			for my $row (@{$rows}) {
				my @cells = map { $_->{Data}->{content} } @{$row->{Cell}};
				print $fh ((join "\t", @cells), "\n");
			}

			++$page;
		}

		close $fh;
	}

	return $filename;
}

sub filter_tjto {
	my ($ano, $mes) = @_;

	my $filename = fetch_tjto($ano, $mes);

	open my $fh, $filename or die;
	binmode $fh, ':utf8';

	while (<$fh>) {
		my ($name, $where, $cargo, $value) = (split /\t/)[0, 1, 2, 9];

		next unless $cargo; # oh well...

		$value =~ s/^R\$ //;
		$value =~ s/\.//g;
		$value =~ s/,/./;

		my $aposentado = $where =~ /APOSENTAD/;

		dump_entry($name, $cargo, $value, 'TJ-TO', $aposentado, $ano, $mes);
	}
}

sub fetch_tjma {
	my ($ano, $mes) = @_;

	# ativo: J04
	# aposentado: I07
	# pensionista: I04

	my $filename_base = sprintf 'tjma-%02d-%04d', $mes, $ano;
	my @filenames = ("${filename_base}.ativo", "${filename_base}.inativo", "${filename_base}.pensionista");
	my @orgao = qw(J04 I07 I04);

	for my $i (0 .. 2) {
		my $filename = $filenames[$i];
		my $orgao = $orgao[$i];

		if (!-e $filename) {
			print STDERR "fetching $filename...\n";

			my $mes_two_digits = sprintf '%02d', $mes;

			my $url = "http://www.tjma.jus.br/financas/impressao.php?rel=anexo_08&orgao=${orgao}&mes=${mes_two_digits}&ano=${ano}&extensao=xls";

			my $user_agent = 'Mozilla/5.0 (Windows; U; Windows NT 6.1; nl; rv:1.9.2.13) Gecko/20101203 Firefox/3.6.13';
			my $bot = WWW::Mechanize->new(agent => $user_agent);

			$bot->get($url, ':content_file' => $filename);
		}
	}

	return \@filenames;
}

sub filter_tjma {
	my ($ano, $mes) = @_;

	my $filenames = fetch_tjma($ano, $mes);

	for my $filename (@{$filenames}) {
		open my $fh, $filename;
		binmode $fh, 'encoding(ISO8859-1)';

		local $/;
		my $data = <$fh>;
		close $fh;

		while ($data =~ /<tr[^>]*>\s*<td[^>]*>[0-9]+<\/td>\s*<td[^>]*>([^<]*)<\/td>\s*<td[^>]*>([^<]*)<\/td>\s*<td[^>]*>([^<]*)<\/td>\s*(<td[^>]*>[^<]*<\/td>\s*){7}<td[^>]*>([^<]*)/gsm) {
			my ($name, $where, $cargo, $value) = ($1, $2, $3, $5);

			$name = uc($name);
			$cargo = uc($cargo);
			$value =~ s/\.//g;
			$value =~ s/,/./;

			my $aposentado = $where =~ /^Aposentad/;
			if ($where =~ /^Pens/) {
				$cargo = 'PENSIONISTA';
			}

			dump_entry($name, $cargo, $value, 'TJ-MA', $aposentado, $ano, $mes);
		}

		close $fh;
	}
}

sub fetch_tjsp {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf 'tjsp-%02d-%04d', $mes, $ano;
	my @filenames = ("${filename_base}.ativo", "${filename_base}.inativo");
	my @ativo = qw(true false);

	for my $i (0 .. 1) {
		my $filename = $filenames[$i];
		my $ativo = $ativo[$i];

		if (!-e $filename) {
			print STDERR "fetching $filename...\n";

			my $user_agent = 'Mozilla/5.0 (Windows; U; Windows NT 6.1; nl; rv:1.9.2.13) Gecko/20101203 Firefox/3.6.13';
			my $bot = WWW::Mechanize->new(agent => $user_agent);

			my $max_length = 5000;

			my $url = 'http://www.tjsp.jus.br/RHF/PortalTransparenciaAPI/sema/FolhaPagamentoMagistrado/ListarTodosPorCargoMesAno';

			$bot->post($url, {
					'draw' => 3,
					'columns[0][data]' => 'nome',
					'columns[0][name]' => '',
					'columns[0][searchable]' => 'true',
					'columns[0][orderable]' => 'false',
					'columns[0][search][value]' => '',
					'columns[0][search][regex]' => 'false',
					'columns[1][data]' => 'lotacao',
					'columns[1][name]' => '',
					'columns[1][searchable]' => 'true',
					'columns[1][orderable]' => 'false',
					'columns[1][search][value]' => '',
					'columns[1][search][regex]' => 'false',
					'columns[2][data]' => 'folhaMagistradoCargo.descricao',
					'columns[2][name]' => '',
					'columns[2][searchable]' => 'true',
					'columns[2][orderable]' => 'false',
					'columns[2][search][value]' => '',
					'columns[2][search][regex]' => 'false',
					'columns[3][data]' => 'totalCredito',
					'columns[3][name]' => '',
					'columns[3][searchable]' => 'true',
					'columns[3][orderable]' => 'false',
					'columns[3][search][value]' => '',
					'columns[3][search][regex]' => 'false',
					'columns[4][data]' => 'totalDebitos',
					'columns[4][name]' => '',
					'columns[4][searchable]' => 'true',
					'columns[4][orderable]' => 'false',
					'columns[4][search][value]' => '',
					'columns[4][search][regex]' => 'false',
					'columns[5][data]' => 'rendimentoLiquido',
					'columns[5][name]' => '',
					'columns[5][searchable]' => 'true',
					'columns[5][orderable]' => 'false',
					'columns[5][search][value]' => '',
					'columns[5][search][regex]' => 'false',
					'columns[6][data]' => 'remuneracaoOrgaoOrigem',
					'columns[6][name]' => '',
					'columns[6][searchable]' => 'true',
					'columns[6][orderable]' => 'false',
					'columns[6][search][value]' => '',
					'columns[6][search][regex]' => 'false',
					'columns[7][data]' => 'diarias',
					'columns[7][name]' => '',
					'columns[7][searchable]' => 'true',
					'columns[7][orderable]' => 'false',
					'columns[7][search][value]' => '',
					'columns[7][search][regex]' => 'false',
					'columns[8][data]' => '',
					'columns[8][name]' => '',
					'columns[8][searchable]' => 'true',
					'columns[8][orderable]' => 'false',
					'columns[8][search][value]' => '',
					'columns[8][search][regex]' => 'false',
					'start' => 0,
					'length' => $max_length,
					'search[value]' => '',
					'search[regex]' => 'false',
					'mes' => $mes,
					'ano' => $ano,
					'ativo' => $ativo,
					'cargoId' => '',
					'nome' => '',
				});

			my $r = $bot->response;

			open my $fh, '>', $filename;
			binmode $fh;
			print $fh $r->content;
			close $fh;
		}
	}

	return \@filenames;
}

sub filter_tjsp {
	my ($ano, $mes) = @_;

	my $filenames = fetch_tjsp($ano, $mes);

	for my $filename (@{$filenames}) {
		open my $fh, $filename or die;
		binmode $fh, ':utf8';

		local $/ = undef;
		my $json_data = <$fh>;
		close $fh;

		my $data = parse_json($json_data);

		for my $record (@{$data->{data}}) {
			my $name = $record->{nome};
			my $cargo = uc($record->{folhaMagistradoCargo}->{descricao});
			my $value = $record->{totalCredito};
			my $aposentado = $record->{ativo} eq 'False';

			dump_entry($name, $cargo, $value, 'TJ-SP', $aposentado, $ano, $mes);
		}

		close $fh;
	}
}

sub fetch_tjsc {
	my ($ano, $mes) = @_;

	my $filename_base = sprintf "tjsc-%02d-%04d", $mes, $ano;

	my @file_info = (
		{ suffix => 'magistrado-ativo', tipo_nome => 'Magistrados Ativos' },
		{ suffix => 'magistrado-inativo', tipo_nome => 'Magistrados Inativos' },
		{ suffix => 'servidor-ativo', tipo_nome => 'Servidores Ativos' },
		{ suffix => 'servidor-inativo', tipo_nome => 'Servidores Inativos' },
	);

	my @filenames;

	for my $i (0 .. scalar @file_info - 1) {
		my $file_info = $file_info[$i];

		my $filename = "$filename_base.$file_info->{suffix}";

		if (!-e $filename) {
=pod
curl 'http://app.tjsc.jus.br/tjsc-consultarendimentos/rest/consulta-rendimento/' -H 'Origin: http://app.tjsc.jus.br' -H 'Accept-Encoding: gzip, deflate' -H 'Accept-Language: en-US,en;q=0.8' -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/58.0.3029.110 Chrome/58.0.3029.110 Safari/537.36' -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'Referer: http://app.tjsc.jus.br/tjsc-consultarendimentos/' -H 'Connection: keep-alive' --data-binary '{"tipoConsulta":{"id":2,"nome":"a partir de janeiro de 2017"},"tipoDocGeracao":{"id":2,"nome":"csv"},"tipoColaborador":{"id":1,"nome":"Magistrados Ativos"},"mes":{"id":4,"nome":"Abril"},"ano":2017,"nomeSolicitante":"JOAQUIN TEIXEIRA","tipoDocumentoSolicitante":{"id":1,"nome":"CPF"},"numeroDocumentoSolicitante":"34686524962"}' --compressed
=cut
			my $tipo_colaborador_id = $i + 1;
			my $tipo_colaborador_nome = $file_info->{tipo_nome};

			my $nome_mes = qw(Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro)[$mes - 1];
			my $content = qq({"tipoConsulta":{"id":2,"nome":"a partir de janeiro de 2017"},"tipoDocGeracao":{"id":2,"nome":"csv"},"tipoColaborador":{"id":$tipo_colaborador_id,"nome":"$tipo_colaborador_nome"},"mes":{"id":$mes,"nome":"$nome_mes"},"ano":$ano,"nomeSolicitante":"$form_name","tipoDocumentoSolicitante":{"id":1,"nome":"CPF"},"numeroDocumentoSolicitante":"$form_cpf_numbers_only"});

			my $bot = WWW::Mechanize->new(agent => $user_agent);
			my $url = 'http://app.tjsc.jus.br/tjsc-consultarendimentos/rest/consulta-rendimento/';
			# my $url = 'http://localhost:8080';

			$bot->add_header('Content-Type' => 'application/json;charset=UTF-8');
			$bot->post($url, Content => encode('utf-8', $content));

			my $r = $bot->response;

			my $id = $r->content;

			my $csv_url = "http://app.tjsc.jus.br/tjsc-consultarendimentos/rest/consulta-rendimento/csv/$form_cpf_numbers_only/$id";
			$bot->get($csv_url, ':content_file' => $filename);
		}
		
		push @filenames, $filename;
	}

	return \@filenames;
}

sub filter_tjsc {
	my ($ano, $mes) = @_;

	my $filenames = fetch_tjsc($ano, $mes);

	for my $filename (@{$filenames}) {
		open my $fh, $filename;
		binmode $fh, ':utf8';

		while (<$fh>) {
			next unless /^[A-Z]/;
			next if /^TOTAL/;

			my ($nome, $where, $cargo, $value) = (split /;/)[0, 1, 2, 12];

			$value =~ s/\.//g;
			$value =~ s/,/./;

			my $aposentado = $where =~ /^APOSENTAD/;

			dump_entry($nome, $cargo, $value, 'TJ-SC', $aposentado, $ano, $mes);
		}

		close $fh;
	}
}

my %sources = (
	'TRT-1' => \&filter_trt1,
	'TRT-2' => \&filter_trt2,
	'TRT-3' => \&filter_trt3,
	'TRT-4' => \&filter_trt4,
	'TRT-5' => \&filter_trt5,
	'TRT-6' => \&filter_trt6,
	'TRT-7' => \&filter_trt7,
	'TRT-8' => \&filter_trt8,
	'TRT-10' => \&filter_trt10,
	'TRT-11' => \&filter_trt11,
	'TRT-12' => \&filter_trt12,
	'TRT-13' => \&filter_trt13,
	'TRT-14' => \&filter_trt14,
	'TRT-15' => \&filter_trt15,
	'TRT-18' => \&filter_trt18,
	'TRT-19' => \&filter_trt19,
	'TRT-22' => \&filter_trt22,
	'TRT-24' => \&filter_trt24,
	'TSE' => \&filter_tse,
	'TST' => \&filter_tst,
	'TRF-1' => \&filter_trf1,
	'TRF-2' => \&filter_trf2,
	'TRE-RJ' => \&filter_trerj,
	'TJ-ES' => \&filter_tjes,
	'TJ-SE' => \&filter_tjse,
	'TJ-RR' => \&filter_tjrr,
	'TJ-PE' => \&filter_tjpe,
	'TJ-TO' => \&filter_tjto,
	'TJ-SP' => \&filter_tjsp,
	'TJ-MA' => \&filter_tjma,
	'TJ-SC' => \&filter_tjsc,
);

my $ano = 2017;

for my $mes (3 .. 11) {
	while (my ($source, $fetcher) = each %sources) {
		print STDERR "filtering $source $mes/$ano...\n";
		eval {
			$fetcher->($ano, $mes);
		};
		if ($@) {
			print STDERR "error fetching $source $mes/$ano: $@\n";
		}
	}
}

# vim: set ts=8 sts=0 sw=8 noet:
