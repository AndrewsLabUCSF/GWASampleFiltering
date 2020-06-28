'''Snakefile for GWAS Variant and Sample QC Version 0.3.1'''

from scripts.parse_config import parser
from snakemake.remote.FTP import RemoteProvider as FTPRemoteProvider
import socket
import sys
import getpass
import warnings

FTP = FTPRemoteProvider()

isMinerva = "hpc.mssm.edu" in socket.getfqdn()

configfile: "./config.yaml"

shell.executable("/bin/bash")

if isMinerva:
    anacondapath = sys.exec_prefix + "/bin"
    shell.prefix(". ~/.bashrc; PATH={}:$PATH; ".format(anacondapath))

# figure out if downloading reference
if config['download_tg']:
    try:
        socket.setdefaulttimeout(3)
        itest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        itest.connect(('8.8.8.8', 53))
        iconnect = True
        predownload = True
    except socket.error as ex:
        warnings.warn("\n\nYou have enabled the download of 1000g reference files but have no internet access.\n"
            "Snakemake will not attempt to download but will look in the data folder.\n")
        predownload = False

BPLINK = ["bed", "bim", "fam"]
RWD = os.getcwd()
start, FAMILY, SAMPLE, DATAOUT = parser(config)

istg = config['isTG'] if 'isTG' in config else False

# QC Steps:
QC_snp = True
QC_callRate = True
union_panel_TF = True

if isMinerva:
    com = {'flippyr': 'flippyr', 'plink': 'plink --keep-allele-order',
           'plink2': 'plink', 'bcftools': 'bcftools', 'R': 'Rscript', 'R2': 'R',
           'king': 'king', 'faidx': 'samtools faidx'}
    loads = {'flippyr': 'module load plink/1.90b6.10', 'plink': 'module load plink/1.90b6.10',
             'bcftools': 'module load bcftools/1.9', 'faidx': 'module load samtools',
             'king': 'module unload gcc; module load king/2.1.6',
             'R': ('module load R/3.6.3 pandoc/2.6 udunits/2.2.26; ',
                   'RSTUDIO_PANDOC=$(which pandoc)')}
else:
    com = {'flippyr': 'flippyr',
           'plink': 'plink --keep-allele-order', 'plink2': 'plink', 'faidx': 'samtools faidx',
           'bcftools': 'bcftools', 'R': 'Rscript', 'R2': 'R', 'king': 'king'}
    loads = {'flippyr': 'echo running flippyr', 'plink': 'echo running plink',
             'bcftools': 'echo running bcftools',  'R': 'echo running R',
             'king': 'echo running KING', 'faidx': 'echo running samtools faidx'}

if getpass.getuser() == "sheaandrews":
    com["flippyr"] = '/Users/sheaandrews/Programs/flippyr/flippyr.py'


def decorate(text):
    return expand(DATAOUT + "/{sample}_" + text,
                  sample=SAMPLE)

localrules: all, download_tg_fa, download_tg_ped, download_tg_chrom

def flatten(nested):
    flat = []
    for el in nested:
        if not isinstance(el, list):
            flat.append(el)
        else:
            flat += flatten(el)
    return flat

outs = {
    "report": expand(DATAOUT + "/stats/{sample}_GWAS_QC.html", sample=SAMPLE),
    "exclusions": expand(DATAOUT + "/{sample}_exclude.samples", sample=SAMPLE),
    "filtered": expand(DATAOUT + "/{sample}_Excluded.{ext}",
        sample=SAMPLE, ext=BPLINK)}

outputs = [outs[x] for x in config["outputs"]]
outputs = flatten(outputs)

rule all:
    input: expand(DATAOUT + "/{sample}_{refname}_merged.vcf", sample=SAMPLE, refname="1kG") # outputs


# ---- Exlude SNPs with a high missing rate and low MAF----
rule snp_qc:
    input: start['files']
    output:
        temp(expand(DATAOUT + "/{{sample}}_SnpQc.{ext}", ext=BPLINK)),
        DATAOUT + "/{sample}_SnpQc.hwe",
        DATAOUT + "/{sample}_SnpQc.frq",
        DATAOUT + "/{sample}_SnpQc.frqx",
    params:
        stem = start['stem'],
        out = DATAOUT + "/{sample}_SnpQc",
        miss = config['QC']['GenoMiss'],
        MAF = config['QC']['MAF'],
        HWE = config['QC']['HWE']
    shell:
        """
{loads[plink]}
{com[plink]} --bfile {params.stem} --freq --out {params.out}
{com[plink]} --bfile {params.stem} --freqx --out {params.out}
{com[plink]} --bfile {params.stem} --geno {params.miss} \
--maf {params.MAF} --hardy --hwe {params.HWE} --make-bed --out {params.out}"""

# ---- Exclude Samples with high missing rate ----
rule sample_callRate:
    input: rules.snp_qc.output if QC_snp else start['files']
    output:
        expand(DATAOUT + "/{{sample}}_callRate.{ext}", ext=BPLINK),
        DATAOUT + "/{sample}_callRate.imiss",
        touch(DATAOUT + "/{sample}_callRate.irem")
    params:
        indat = rules.snp_qc.params.out if QC_snp else start['stem'],
        miss = config['QC']['SampMiss'],
        out = DATAOUT + "/{sample}_callRate"
    shell:
        """
{loads[plink]}
{com[plink]} --bfile {params.indat} --mind {params.miss} \
--missing --make-bed --out {params.out}"""

# ---- Exclude Samples with discordant sex ----
#  Use ADNI hg18 data, as the liftover removed the x chromsome data


rule sexcheck_QC:
    input: start['sex']
    output:
        DATAOUT + "/{sample}_SexQC.sexcheck"
    params:
        indat = start['sex_stem'],
        out = DATAOUT + "/{sample}_SexQC",
    shell:
        '''
{loads[plink]}
{com[plink]} --bfile {params.indat} --check-sex --aec --out {params.out}
'''

rule sex_sample_fail:
    input:
        rules.sexcheck_QC.output
    output:
        DATAOUT + "/{sample}_exclude.sexcheck",
    shell:
        '{loads[R]}; {com[R]} scripts/sexcheck_QC.R {input} {output}'

if QC_callRate:
    sexcheck_in_plink = rules.sample_callRate.output[0]
    sexcheck_in_plink_stem = rules.sample_callRate.params.out
elif QC_snp:
    sexcheck_in_plink = rules.snp_qc.output
    sexcheck_in_plink_stem = rules.snp_qc.params.out
else:
    sexcheck_in_plink = start['files']
    sexcheck_in_plink_stem = start['stem']

# ---- Principal Compoent analysis ----
#  Project ADNI onto a PCA using the 1000 Genomes dataset to identify
#    population outliers

#  Extract a pruned dataset from 1000 genomes using the same pruning SNPs
#    from Sample
# align 1000 genomes to fasta refrence


#tgbase = "ftp://ftp.1000genomes.ebi.ac.uk/vol1/ftp/"
tgbase = "ftp://ftp-trace.ncbi.nih.gov/1000genomes/ftp/"
tgped = tgbase + "technical/working/20130606_sample_info/20130606_g1k.ped"

if config['genome_build'] in ['hg19', 'hg37', 'GRCh37', 'grch37', 'GRCH37']:
    BUILD = 'hg19'
    tgurl = (tgbase + "release/20130502/ALL.chr{chrom}." +
        "phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz")
    tgfa = tgbase + "technical/reference/human_g1k_v37.fasta"
elif config['genome_build'] in ['hg38', 'GRCh38', 'grch38', 'GRCH38']:
    BUILD = 'GRCh38'
    tgurl = (tgbase +
        'data_collections/1000_genomes_project/release/20181203_biallelic_SNV/' +
        'ALL.chr{chrom}.shapeit2_integrated_v1a.GRCh38.20181129.phased.vcf.gz')
    tgfa = 'technical/reference/GRCh38_reference_genome/GRCh38_full_analysis_set_plus_decoy_hla.fa'


if predownload:
    rule download_tg_chrom:
       input:
           FTP.remote(tgurl, keep_local=True),
           FTP.remote(tgurl + ".tbi", keep_local=True),
       output:
           temp("data/1000gRaw.{gbuild}.chr{chrom}.vcf.gz"),
           temp("data/1000gRaw.{gbuild}.chr{chrom}.vcf.gz.tbi")
       shell: "cp {input[0]} {output[0]}; cp {input[1]} {output[1]}"

    rule download_tg_fa:
       input:
           FTP.remote(tgfa + ".gz") if BUILD == 'hg19' else FTP.remote(tgfa)
       output:
           "data/human_g1k_{gbuild}.fasta",
           "data/human_g1k_{gbuild}.fasta.fai"
       shell:
           """
{loads[faidx]}
if [[ "{input[0]}" == *.gz ]]; then
  zcat {input[0]} > {output[0]}
else
  cp {input[0]} {output[0]}
fi
{com[faidx]} {output[0]}"""

    rule download_tg_ped:
       input:
           FTP.remote(tgped, keep_local=True),
       output:
           "data/20130606_g1k.ped",
       shell: "cp {input} {output}"

tgped = "data/20130606_g1k.ped"
tg_refraw = ["data/1000gRaw.{gbuild}.chr{chrom}.vcf.gz",
          "data/1000gRaw.{gbuild}.chr{chrom}.vcf.gz.tbi"]

rule makeTGpops:
    input: tgped
    output:
        "data/1000genomes_pops.txt",
        "data/pops.txt"
    shell:
        """
awk 'BEGIN {{print "FID","IID","Population"}} NR>1 {{print $1,$2,$7}}' \
{input} > {output[0]}
cut -f7 {input} | sed 1d | sort | uniq > {output[1]}
"""

if (not "custom_ref" in config) or (not config['custom_ref']):
    REF = '1kG'
    rule Reference_prep:
        input: tg_refraw
        output: temp("data/1kG.{gbuild}.chr{chrom}.maxmiss{miss}.vcf.gz")
        shell:
            """
    {loads[bcftools]}
    {com[bcftools]} norm -m- {input[0]} --threads 2 | \
    {com[bcftools]} view -v snps --min-af 0.01:minor -i 'F_MISSING <= {wildcards.miss}' --threads 2 | \
    {com[bcftools]} annotate --set-id '%CHROM:%POS:%REF:%ALT' --threads 6 -Oz -o {output}
    """

    """
    Selects everyone who is unrelated or only has third degree relatives in
    thousand genomes.
    """
    rule Reference_foundersonly:
        input: tgped
        output:
            "data/20130606_g1k.founders"
        shell: r"""
    awk -F "\t" '!($12 != 0 || $10 != 0 || $9 != 0 || $3 != 0 || $4 != 0) {{print $2}}' \
    {input} > {output}
    """

    rule Reference_cat:
        input:
            vcfs = expand("data/1kG.{{gbuild}}.chr{chrom}.maxmiss{{miss}}.vcf.gz",
                          chrom = list(range(1, 23)))
        output:
            vcf = "data/1kG_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
            tbi = "data/1kG_{gbuild}_allChr_maxmiss{miss}.vcf.gz.tbi"
        shell:
            """
    {loads[bcftools]}
    {com[bcftools]} concat {input.vcfs} -Oz -o {output.vcf} --threads 2
    {com[bcftools]} index -ft {output.vcf}
    """
elif '.vcf' in config['custom_ref'] or '.bcf' in config['custom_ref']:
    REF = config['custom_ref_name']
    if '{chrom}' in config['custom_ref']:
        rule Reference_prep:
            input: config['custom_ref']
            output: temp("data/{refname}.{gbuild}.chr{chrom}.maxmiss{miss}.vcf.gz")
            shell:
                """
        {loads[bcftools]}
        {com[bcftools]} norm -m- {input} --threads 2 | \
        {com[bcftools]} view -v snps --min-af 0.01:minor -i 'F_MISSING <= {wildcards.miss}' --threads 2 | \
        {com[bcftools]} annotate --set-id '%CHROM:%POS:%REF:%ALT' --threads 6 -Oz -o {output}
        """

        rule Reference_cat:
            input:
                vcfs = expand("data/{{refname}}.{{gbuild}}.chr{chrom}.maxmiss{{miss}}.vcf.gz",
                              chrom = list(range(1, 23)))
            output:
                vcf = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
                tbi = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz.tbi"
            shell:
                """
        {loads[bcftools]}
        {com[bcftools]} concat {input.vcfs} -Oz -o {output.vcf} --threads 2
        {com[bcftools]} index -ft {output.vcf}
        """
    else:
        rule Reference_prep:
            input: config['custom_ref']
            output:
                vcf = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
                tbi = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz.tbi"
            shell:
                """
        {loads[bcftools]}
        {com[bcftools]} norm -m- {input.vcf} --threads 2 | \
        {com[bcftools]} view -v snps --min-af 0.01:minor -i 'F_MISSING <= {wildcards.miss}' --threads 2 | \
        {com[bcftools]} annotate --set-id '%CHROM:%POS:%REF:%ALT' --threads 6 -Oz -o {output.vcf}
        {com[bcftools]} index -ft {output.vcf}
        """
else: #PLINK fileset of all chromosomes
    REF = config['custom_ref_name']
    # align custom ref to fasta refrence
    rule Ref_Flip:
        input:
            bim = config['custom_ref'] + '.bim',
            bed = config['custom_ref'] + '.bed',
            fam = config['custom_ref'] + '.fam',
            fasta = expand("data/human_g1k_{gbuild}.fasta", gbuild=BUILD)
        output:
            temp(expand("data/{{refname}}_flipped.{ext}", ext=BPLINK))
        shell:
            """
    {loads[flippyr]}
    {com[flippyr]} -p {input.fasta} -o {DATAOUT}/{wildcards.refname} {input.bim}"""

    rule Ref_ChromPosRefAlt:
        input:
            flipped = "data/{refname}_flipped.bim"
        output:
            bim = temp("data/{refname}_flipped_ChromPos.bim"),
            snplist = temp("data/{refname}_flipped_snplist")
        shell:
            """
    {loads[R]}
    {com[R]} scripts/bim_ChromPosRefAlt.R {input} {output.bim} {output.snplist}"""

    # Recode sample plink file to vcf
    rule Ref_Plink2Vcf:
        input:
            bim = rules.Ref_ChromPosRefAlt.output,
            flipped = rules.Ref_Flip.output
        output:
            temp("data/{refname}_{gbuild}.vcf.gz")
        params:
            out = "data/{refname}_{gbuild}",
            inp = "data/{refname}_flipped"
        shell:
            """
    {loads[plink]}
    {com[plink2]} --bfile {input.flipped} --bim {input.bim} --recode vcf bgz \
    --real-ref-alleles --out {params.out}"""

    # Index bcf
    rule Ref_IndexVcf:
        input: "data/{refname}_{gbuild}.vcf.gz"
        output: "data/{refname}_{gbuild}.vcf.gz.csi"
        shell: '{loads[bcftools]}; {com[bcftools]} index -f {input}'

    rule Reference_prep:
       input:
            vcf = rules.Ref_Plink2Vcf.output,
            csi = rules.Ref_IndedVcf.output
       output:
            vcf = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
            tbi = "data/{refname}_{gbuild}_allChr_maxmiss{miss}.vcf.gz.tbi"
       shell:
            """
{loads[bcftools]}
{com[bcftools]} norm -m- {input.vcf} --threads 2 | \
{com[bcftools]} view -v snps --min-af 0.01:minor -i 'F_MISSING <= {wildcards.miss}' --threads 2 | \
{com[bcftools]} annotate --set-id '%CHROM:%POS:%REF:%ALT' --threads 6 -Oz -o {output.vcf}
{com[bcftools]} index -ft {output.vcf}
"""

# ---- Prune SNPs, autosome only ----
#  Pruned SNP list is used for IBD, PCA and heterozigosity calculations

# align sample to fasta refrence
rule Sample_Flip:
    input:
        bim = sexcheck_in_plink_stem + '.bim',
        bed = sexcheck_in_plink_stem + '.bed',
        fam = sexcheck_in_plink_stem + '.fam',
        fasta = expand("data/human_g1k_{gbuild}.fasta", gbuild=BUILD)
    output:
        temp(expand(DATAOUT + "/{{sample}}_flipped.{ext}",
                    ext=BPLINK))
    shell:
        """
{loads[flippyr]}
{com[flippyr]} -p {input.fasta} -o {DATAOUT}/{wildcards.sample} {input.bim}"""

rule Sample_ChromPosRefAlt:
    input:
        flipped = DATAOUT + "/{sample}_flipped.bim"
    output:
        bim = temp(DATAOUT + "/{sample}_flipped_ChromPos.bim"),
        snplist = temp(DATAOUT + "/{sample}_flipped_snplist")
    shell:
        """
{loads[R]}
{com[R]} scripts/bim_ChromPosRefAlt.R {input} {output.bim} {output.snplist}"""

panel_variants = 'panelvars_{refname}.snps'

rule get_panelvars:
    input:
        expand("data/{{refname}}_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
               gbuild=BUILD, miss=config['QC']['GenoMiss']),
    output: panel_variants
    shell:
        """
{loads[bcftools]}
{com[bcftools]} query -f '%ID\n' {input} > {output}
"""

if union_panel_TF:
    PVARS = expand(panel_variants, refname=REF)
    extract_sample = "--extract {} ".format(panel_variants).format(refname=REF)
else:
    PVARS = "/dev/urandom"
    extract_sample = ""

rule PruneDupvar_snps:
    input:
        fileset = rules.Sample_ChromPosRefAlt.input,
        bim = rules.Sample_ChromPosRefAlt.output.bim,
        pvars = PVARS
    output:
        expand(DATAOUT + "/{{sample}}_nodup.{ext}",
               ext=['prune.in', 'prune.out']),
        DATAOUT + "/{sample}_nodup.dupvar.delete"
    params:
        indat = sexcheck_in_plink_stem,
        dupvar = DATAOUT + "/{sample}_nodup.dupvar",
        out = DATAOUT + "/{sample}_nodup",
        extract = extract_sample
    shell:
        """
{loads[plink]}
{loads[R]}
{com[plink]} --bfile {params.indat} -bim {input.bim} \
{params.extract}--autosome --indep 50 5 1.5 \
--list-duplicate-vars --out {params.out}
{com[R]}  scripts/DuplicateVars.R {params.dupvar}"""

# Prune sample dataset
rule sample_prune:
    input:
        sexcheck_in_plink,
        prune = DATAOUT + "/{sample}_nodup.prune.in",
        dupvar = DATAOUT + "/{sample}_nodup.dupvar.delete"
    output:
        temp(expand(DATAOUT + "/{{sample}}_pruned.{ext}",
                    ext=BPLINK))
    params:
        indat_plink = sexcheck_in_plink_stem,
        out = DATAOUT + "/{sample}_pruned"
    shell:
        """
{loads[plink]}
{com[plink]} --bfile {params.indat_plink} --extract {input.prune} \
--exclude {input.dupvar} --make-bed --out {params.out}"""

rule sample_make_prunelist:
  input: DATAOUT + "/{sample}_pruned.bim"
  output: DATAOUT + "/{sample}_pruned.snplist"
  shell: "cut -f2 {input} > {output}"

#TODO fix founders for custom ref
rule Reference_prune:
    input:
        vcf = expand("data/{{refname}}_{gbuild}_allChr_maxmiss{miss}.vcf.gz",
                     gbuild=BUILD, miss=config['QC']['GenoMiss']),
        prune = DATAOUT + "/{sample}_pruned.snplist",
        founders = "data/20130606_g1k.founders"
    output:
        vcf = temp(DATAOUT + "/{sample}_{refname}pruned.vcf.gz"),
        tbi = temp(DATAOUT + "/{sample}_{refname}pruned.vcf.gz.tbi")
    shell:
        """
{loads[bcftools]}
{com[bcftools]} view -i 'ID=@{input.prune}' -S {input.founders} \
-Oz -o {output.vcf} --force-samples {input.vcf} --threads 4
{com[bcftools]} index -ft {output.vcf}
"""

# allow for tg sample:
rule tgfam:
    input: DATAOUT + "/{sample}_pruned.fam"
    output: DATAOUT + "/{sample}_pruned_tg.fam"
    shell: """awk '$1 = "1000g___"$1 {{print}}' {input} > {output}"""

# Recode sample plink file to vcf
rule Sample_Plink2Bcf:
    input:
        bed = DATAOUT + "/{sample}_pruned.bed",
        bim = DATAOUT + "/{sample}_pruned.bim",
        fam = rules.tgfam.output if istg else rules.tgfam.input
    output: DATAOUT + "/{sample}_pruned.vcf.gz"
    params:
        out = DATAOUT + "/{sample}_pruned"
    shell:
        """
{loads[plink]}
{com[plink2]} --bed {input.bed} --bim {input.bim} --fam {input.fam} --recode vcf bgz \
--real-ref-alleles --out {params.out}"""

# Index bcf
rule Sample_IndexBcf:
    input: DATAOUT + "/{sample}_pruned.vcf.gz"
    output: DATAOUT + "/{sample}_pruned.vcf.gz.csi"
    shell: '{loads[bcftools]}; {com[bcftools]} index -f {input}'

# Merge ref and sample
rule Merge_RefenceSample:
    input:
        bcf_1kg = DATAOUT + "/{sample}_{refname}pruned.vcf.gz",
        tbi_1kg = DATAOUT + "/{sample}_{refname}pruned.vcf.gz.tbi",
        bcf_samp = DATAOUT + "/{sample}_pruned.vcf.gz",
        csi_samp = DATAOUT + "/{sample}_pruned.vcf.gz.csi"
    params:
        miss = config['QC']['GenoMiss']
    output:
        out = DATAOUT + "/{sample}_{refname}_merged.vcf"
    shell:
        r"""
{loads[bcftools]}
{com[bcftools]} merge -m none --threads 2 {input.bcf_1kg} {input.bcf_samp} | \
{com[bcftools]} view  -i 'F_MISSING <= {params.miss}' -Ov -o {output.out} --threads 2"""

# recode merged sample to plink
rule Plink_RefenceSample:
    input:
        vcf = DATAOUT + "/{sample}_{refname}_merged.vcf"
    output:
        expand(DATAOUT + "/{{sample}}_{{refname}}_merged.{ext}", ext=BPLINK)
    params:
        out = DATAOUT + "/{sample}_{refname}_merged"
    shell:
        '''
{loads[plink]}
{com[plink]} --vcf {input.vcf} --const-fid --make-bed --out {params.out}'''

rule fix_fam:
    input:
        oldfam = rules.Sample_Plink2Bcf.input.fam,
        newfam = DATAOUT + "/{sample}_{refname}_merged.fam",
        tgped = tgped
    output: DATAOUT + "/{sample}_{refname}_merged_fixed.fam"
    shell:
        """
{loads[R]}
{com[R]} scripts/fix_fam.R {input.oldfam} {input.newfam} {output} {input.tgped}"""

# PCA analysis to identify population outliers
rule PcaPopulationOutliers:
    input:
        plink = expand(DATAOUT + "/{{sample}}_{{refname}}_merged.{ext}", ext=BPLINK),
        fam = rules.fix_fam.output,
        pop = "data/1000genomes_pops.txt",
        clust = "data/pops.txt"
    output:
        expand(DATAOUT + "/{{sample}}_{{refname}}_merged.{ext}", ext=['eigenval', 'eigenvec'])
    params:
        indat_plink = DATAOUT + "/{sample}_{refname}_merged",
        out = DATAOUT + "/{sample}_{refname}_merged"
    shell:
        """
{loads[plink]}
{com[plink]} --bfile {params.indat_plink} --fam {input.fam} --pca 10 \
--within {input.pop} --pca-clusters {input.clust} --out {params.out}
"""

# Rscript to identify population outliers
rule ExcludePopulationOutliers:
    input:
        eigenval = expand(DATAOUT + "/{{sample}}_{refname}_merged.eigenval", refname=REF),
        eigenvec = expand(DATAOUT + "/{{sample}}_{refname}_merged.eigenvec", refname=REF),
        fam = rules.Sample_Plink2Bcf.input.fam,
        tgped = tgped
    output:
        excl = DATAOUT + "/{sample}_exclude.pca",
        rmd = temp(DATAOUT + "/{sample}_pca.Rdata")
    params:
        samp = "{sample}",
        superpop = config['superpop']
    shell:
        """
{loads[R]}
scripts/PCA_QC.R -s {params.samp} -p {params.superpop} \
--vec {input.eigenvec} --val {input.eigenval} \
-b {input.tgped} -t {input.fam} -o {output.excl} -R {output.rmd}
"""

# ---- Exclude Samples with interealtedness ----
rule relatedness_sample_prep:
    input: sexcheck_in_plink
    output:
        bed = temp(DATAOUT + "/{sample}_IBDQCfilt.bed"),
        bim = temp(DATAOUT + "/{sample}_IBDQCfilt.bim"),
        fam = temp(DATAOUT + "/{sample}_IBDQCfilt.fam")
    params:
        indat_plink = sexcheck_in_plink_stem,
        out = DATAOUT + "/{sample}_IBDQCfilt"
    shell:
        """
{loads[plink]}
{com[plink2]} --bfile {params.indat_plink} \
  --geno 0.02 \
  --maf 0.02 \
  --memory 6000 \
  --make-bed --out {params.out}"""

if config['king']:
    rule relatedness_QC:
        input:
            bed = rules.relatedness_sample_prep.output.bed,
            bim = rules.relatedness_sample_prep.output.bim,
            fam = rules.relatedness_sample_prep.output.fam
        output:
            genome = DATAOUT + "/{sample}_IBDQC.kingfiles"
        params:
            out = DATAOUT + "/{sample}_IBDQC"
        shell:
            """
{loads[king]}
{com[king]} -b {input.bed} --related --degree 3 --prefix {params.out}
if test -n "$(find {DATAOUT} -name "{wildcards.sample}_IBDQC.kin*")"; then
  find {DATAOUT} -name "{wildcards.sample}_IBDQC.kin*" > {output.genome}
fi
"""

    rule king_all:
        input:
            bed = rules.relatedness_sample_prep.output.bed,
            bim = rules.relatedness_sample_prep.output.bim,
            fam = rules.relatedness_sample_prep.output.fam
        output:
            genome = DATAOUT + "/{sample}_IBDQC.all.kingfiles",
        params:
            out = DATAOUT + "/{sample}_IBDQC.all"
        shell:
            """
{loads[king]}
{com[king]} -b {input.bed} --kinship --ibs --prefix {params.out}
if test -n "$(find {DATAOUT} -name "{wildcards.sample}_IBDQC.all.kin*")"; then
  find {DATAOUT} -name "{wildcards.sample}_IBDQC.all.kin*" > {output.genome}
fi
"""
else:
    rule relatedness_QC:
        input: rules.sample_prune.output
        output:
            genome = DATAOUT + "/{sample}_IBDQC.genome"
        params:
            indat_plink = DATAOUT + "/{sample}_pruned",
            out = DATAOUT + "/{sample}_IBDQC"
        shell:
            """
{loads[plink]}
{com[plink]} --bfile {params.indat_plink} --genome --min 0.05 \
--out {params.out}"""

rule relatedness_sample_fail:
    input:
        genome = rules.relatedness_QC.output.genome,
        geno_all = rules.king_all.output if config['king'] else "/dev/null",
        fam = sexcheck_in_plink_stem + ".fam"
    params:
        Family = FAMILY,
        king = config['king'],
        threshold = 0.1875,
        geno = rules.relatedness_QC.params.out if config['king'] else rules.relatedness_QC.output.genome
    output:
        out = DATAOUT + "/{sample}_exclude.relatedness",
        rdat = DATAOUT + "/{sample}_IBDQC.Rdata"
    shell:
        """
{loads[R]}; {com[R]}  scripts/relatedness_QC.R {params.geno} {params.threshold} \
{params.Family} {params.king} {output.out} {output.rdat}"""

# ---- Exclude Samples with outlying heterozigosity ----
rule heterozygosity_QC:
    input: rules.sample_prune.output
    output: DATAOUT + "/{sample}_HetQC.het"
    params:
        indat_plink = rules.sample_prune.params.out,
        out = DATAOUT + "/{sample}_HetQC"
    shell:
        '''
{loads[plink]}
{com[plink]} --bfile {params.indat_plink} --het --out {params.out}'''

rule heterozygosity_sample_fail:
    input: rules.heterozygosity_QC.output
    output: DATAOUT + "/{sample}_exclude.heterozigosity"
    shell: '{loads[R]}; {com[R]}  scripts/heterozygosity_QC.R {input} {output}'

# Run PCA to control for population stratification
if config['pcair']:
    assert config['king'], "You must use KING for relatedness if using PCAiR!"
    rule ancestryFilt:
        input:
            plink = expand(DATAOUT + "/{{sample}}_pruned.{ext}",
                           ext=BPLINK),
            exclude = DATAOUT + "/{sample}_exclude.pca"
        output:
            temp(expand(DATAOUT + "/{{sample}}_filtered_PCApre.{ext}",
                 ext=BPLINK)),
        params:
            indat = DATAOUT + "/{sample}_pruned",
            plinkout = DATAOUT + "/{sample}_filtered_PCApre"
        shell:
            r"""
{loads[plink]}
{com[plink]} --bfile {params.indat} \
  --remove {input.exclude} \
  --make-bed --out {params.plinkout}
"""

    rule filterKING:
        input:
            king = DATAOUT + "/{sample}_IBDQC.all.kingfiles",
            exclude = DATAOUT + "/{sample}_exclude.pca"
        output:
            DATAOUT + "/{sample}_IBDQC.all.popfilt.kingfiles"
        params:
            indat = DATAOUT + "/{sample}_IBDQC.all",
        shell:
            r"""
{loads[R]}
{com[R]} scripts/filterKing.R {params.indat} {input.exclude}
if test -n "$(find {DATAOUT} -name "{wildcards.sample}_IBDQC.all.popfilt.kin*")"; then
  find {DATAOUT} -name "{wildcards.sample}_IBDQC.all.popfilt.kin*" > {output}
fi
"""

    rule PCAPartitioning:
        input:
            plink = rules.ancestryFilt.output,
            king = rules.filterKING.output,
            iterative = rules.relatedness_sample_fail.output.out
        output:
            expand(DATAOUT + "/{{sample}}_filtered_PCApre.{ext}",ext=['unrel', 'partition.log'])
        params:
            stem = rules.ancestryFilt.params.plinkout,
            king = rules.filterKING.params.indat + ".popfilt"
        shell:
            """
{loads[R]}
{com[R]} scripts/PartitionPCAiR.R {params.stem} {params.king} {input.iterative}
"""

    rule stratFrq:
        input:
            plink = rules.ancestryFilt.output,
            unrel = rules.PCAPartitioning.output[0],
        output: DATAOUT + "/{sample}_filtered_PCAfreq.frqx"
        params:
            indat = rules.ancestryFilt.params.plinkout,
            out = DATAOUT + "/{sample}_filtered_PCAfreq"
        shell:
            """
{loads[plink]}
{com[plink]} --bfile {params.indat} --freqx \
  --within {input.unrel} --keep-cluster-names unrelated \
  --out {params.out}
"""

    rule PopulationStratification:
        input:
            plink = rules.ancestryFilt.output,
            unrel = rules.PCAPartitioning.output[0],
            frq = rules.stratFrq.output
        output:
            expand(DATAOUT + "/{{sample}}_filtered_PCA.{ext}", ext=['eigenval', 'eigenvec'])
        params:
            indat = rules.ancestryFilt.params.plinkout,
            out = DATAOUT + "/{sample}_filtered_PCA"
        shell:
            """
{loads[plink]}
{com[plink]} --bfile {params.indat} --read-freq {input.frq} --pca 10 \
  --within {input.unrel} --pca-cluster-names unrelated \
  --out {params.out}
"""
else:
    rule PopulationStratification:
        input:
            plink = expand(DATAOUT + "/{{sample}}_pruned.{ext}",
                           ext=BPLINK),
            exclude = DATAOUT + "/{sample}_exclude.pca"
        output:
            expand(DATAOUT + "/{{sample}}_filtered_PCA.{ext}", ext=['eigenval', 'eigenvec'])
        params:
            indat = DATAOUT + "/{sample}_pruned",
            out = DATAOUT + "/{sample}_filtered_PCA"
        shell:
            """
{loads[plink]}
{com[plink]} --bfile {params.indat} --remove {input.exclude} --pca 10 \
--out {params.out}
"""

rule SampleExclusion:
    input:
        SampCallRate = DATAOUT + "/{sample}_callRate.irem",
        het = DATAOUT + "/{sample}_exclude.heterozigosity",
        sex = DATAOUT + "/{sample}_exclude.sexcheck",
        pca = DATAOUT + "/{sample}_exclude.pca",
        relat = DATAOUT + "/{sample}_exclude.relatedness"
    output:
        out = DATAOUT + "/{sample}_exclude.samples",
        out_distinct = DATAOUT + "/{sample}_exclude.distinct_samples"
    shell:
        """
{loads[R]}
{com[R]} scripts/sample_QC.R {input.SampCallRate} {input.het} \
{input.sex} {input.pca} {input.relat} {output.out} {output.out_distinct}
"""

rule Exclude_failed:
    input:
        plink = sexcheck_in_plink,
        indat_exclude = rules.SampleExclusion.output.out_distinct
    output:
        temp(expand(DATAOUT + "/{{sample}}_Excluded.{ext}", ext=BPLINK)),
        excl = temp(DATAOUT + '/{sample}_exclude.plink')
    params:
        indat_plink = sexcheck_in_plink_stem,
        out = DATAOUT + "/{sample}_Excluded"
    shell:
        """
cat {input.indat_exclude} | sed '1d' | cut -d' ' -f1,2 > {output.excl}
{loads[plink]}
{com[plink]} --bfile {params.indat_plink} --remove {output.excl} \
--make-bed --out {params.out}"""


def decorate2(text):
    return DATAOUT + "/{sample}_" + text


rule GWAS_QC_Report:
    input:
        script = "scripts/GWAS_QC.Rmd",
        SexFile = decorate2("SexQC.sexcheck"),
        hwe = decorate2("SnpQc.hwe"),
        frq = decorate2("SnpQc.frq"),
        frqx = decorate2("SnpQc.frqx"),
        imiss = decorate2("callRate.imiss"),
        HetFile = decorate2("HetQC.het"),
        IBD_stats = decorate2("IBDQC.Rdata"),
        PCA_rdat = decorate2("pca.Rdata"),
        PopStrat_eigenval = decorate2("filtered_PCA.eigenval"),
        PopStrat_eigenvec = decorate2("filtered_PCA.eigenvec"),
        partmethod = rules.PCAPartitioning.output[1] if config["pcair"] else "/dev/null"
    output:
        DATAOUT + "/stats/{sample}_GWAS_QC.html"
    params:
        rwd = RWD,
        Family = FAMILY,
        pi_threshold = 0.1875,
        output_dir = DATAOUT + "/stats",
        idir = DATAOUT + "/stats/md/{sample}",
        geno_miss = config['QC']['GenoMiss'],
        samp_miss = config['QC']['SampMiss'],
        MAF = config['QC']['MAF'],
        HWE = config['QC']['HWE'],
        superpop = config['superpop'],
        partmethod = rules.PCAPartitioning.output[1] if config["pcair"] else "none"
    shell:
        """
{loads[R]}
{com[R2]} -e 'nm <- sample(c("Shea J. Andrews", "Brian Fulton-Howard"), \
replace=F); nm <- paste(nm[1], "and", nm[2]); \
rmarkdown::render("{input.script}", output_dir = "{params.output_dir}", \
output_file = "{output}", intermediates_dir = "{params.idir}", \
params = list(rwd = "{params.rwd}", Sample = "{wildcards.sample}", \
auth = nm, Path_SexFile = "{input.SexFile}", Path_hwe = "{input.hwe}", \
Path_frq = "{input.frq}", Path_frqx = "{input.frqx}", \
Path_imiss = "{input.imiss}", Path_HetFile = "{input.HetFile}", \
pi_threshold = {params.pi_threshold}, Family = {params.Family}, \
Path_IBD_stats = "{input.IBD_stats}", Path_PCA_rdat = "{input.PCA_rdat}", \
Path_PopStrat_eigenval = "{input.PopStrat_eigenval}", \
Path_PopStrat_eigenvec = "{input.PopStrat_eigenvec}", maf = {params.MAF}, \
hwe = {params.HWE}, missing_geno = {params.geno_miss}, \
partmethod = "{params.partmethod}", \
missing_sample = {params.samp_miss}, superpop = "{params.superpop}"))' --slave
"""
