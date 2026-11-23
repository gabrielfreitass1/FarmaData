"""Camada de acesso a dados (PostgreSQL Star Schema + Bases Auxiliares) e fallback demonstrativo.

Integra a tabela fato dimensional (`fato_venda_medicamento`) e dimensões conformadas
(`dim_municipio`, `dim_tempo`) com todas as bases públicas auxiliares do projeto:
  1. IBGE População por Município (`ibge_populacao_municipio`, SIDRA 6579)
  2. INMET Clima Mensal por UF (`clima_mensal_uf`, temperatura e precipitação)
  3. IBGE População por Faixa Etária (`ibge_populacao_faixa_etaria_municipio`, Censo 2022)
  4. DATASUS Catálogo CID-10 (`cid10`)
"""

from __future__ import annotations

import os
from typing import Optional, Tuple

import numpy as np
import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text

ANO_RECORTE = int(os.environ.get("ANO_RECORTE", "2020"))
POP_MIN_PER_CAPITA = 30_000

UF_META = [
    ("AC", "Acre", "Norte", 894_470, 26.2, 2.0, 1950, 0.088, 0.285),
    ("AL", "Alagoas", "Nordeste", 3_351_543, 25.8, 2.2, 1320, 0.132, 0.238),
    ("AM", "Amazonas", "Norte", 4_207_714, 27.1, 1.4, 2320, 0.085, 0.282),
    ("AP", "Amapá", "Norte", 861_773, 27.0, 1.5, 2450, 0.082, 0.278),
    ("BA", "Bahia", "Nordeste", 14_930_634, 24.9, 2.8, 1080, 0.145, 0.215),
    ("CE", "Ceará", "Nordeste", 9_187_103, 26.6, 1.9, 1050, 0.143, 0.218),
    ("DF", "Distrito Federal", "Centro-Oeste", 3_055_149, 21.6, 4.4, 1480, 0.128, 0.195),
    ("ES", "Espírito Santo", "Sudeste", 4_064_052, 23.6, 4.1, 1260, 0.158, 0.196),
    ("GO", "Goiás", "Centro-Oeste", 7_113_540, 23.4, 4.2, 1520, 0.137, 0.205),
    ("MA", "Maranhão", "Nordeste", 7_114_598, 27.0, 1.7, 1780, 0.118, 0.256),
    ("MG", "Minas Gerais", "Sudeste", 21_292_666, 21.3, 5.2, 1380, 0.174, 0.184),
    ("MS", "Mato Grosso do Sul", "Centro-Oeste", 2_809_394, 23.2, 6.1, 1420, 0.144, 0.212),
    ("MT", "Mato Grosso", "Centro-Oeste", 3_526_220, 25.4, 3.6, 1690, 0.116, 0.228),
    ("PA", "Pará", "Norte", 8_690_745, 26.8, 1.6, 2240, 0.105, 0.262),
    ("PB", "Paraíba", "Nordeste", 4_039_277, 25.6, 2.3, 980, 0.152, 0.218),
    ("PE", "Pernambuco", "Nordeste", 9_616_621, 25.4, 2.4, 1120, 0.146, 0.216),
    ("PI", "Piauí", "Nordeste", 3_281_480, 27.2, 2.1, 1150, 0.144, 0.222),
    ("PR", "Paraná", "Sul", 11_516_840, 19.3, 7.6, 1620, 0.167, 0.188),
    ("RJ", "Rio de Janeiro", "Sudeste", 17_366_189, 23.2, 4.9, 1290, 0.184, 0.178),
    ("RN", "Rio Grande do Norte", "Nordeste", 3_534_165, 26.4, 1.9, 920, 0.146, 0.212),
    ("RO", "Rondônia", "Norte", 1_796_460, 25.7, 2.4, 1980, 0.110, 0.236),
    ("RR", "Roraima", "Norte", 631_181, 27.3, 1.5, 1850, 0.076, 0.292),
    ("RS", "Rio Grande do Sul", "Sul", 11_422_973, 18.1, 9.2, 1580, 0.198, 0.172),
    ("SC", "Santa Catarina", "Sul", 7_252_502, 18.9, 8.2, 1680, 0.164, 0.184),
    ("SE", "Sergipe", "Nordeste", 2_318_822, 25.9, 2.2, 1210, 0.133, 0.224),
    ("SP", "São Paulo", "Sudeste", 46_289_333, 21.1, 5.8, 1410, 0.171, 0.182),
    ("TO", "Tocantins", "Norte", 1_590_248, 26.5, 2.5, 1640, 0.119, 0.242),
]

MESES_NOMES = {
    1: "Jan", 2: "Fev", 3: "Mar", 4: "Abr", 5: "Mai", 6: "Jun",
    7: "Jul", 8: "Ago", 9: "Set", 10: "Out", 11: "Nov", 12: "Dez",
}


def get_database_url() -> str:
    raw = os.environ.get(
        "DATABASE_URL",
        "postgresql+psycopg2://postgres:postgres@localhost:5432/farmadata",
    )
    if raw.startswith("postgresql://"):
        return raw.replace("postgresql://", "postgresql+psycopg2://", 1)
    if raw.startswith("postgres://"):
        return raw.replace("postgres://", "postgresql+psycopg2://", 1)
    return raw


@st.cache_resource
def get_engine():
    try:
        engine = create_engine(
            get_database_url(),
            pool_pre_ping=True,
            connect_args={"connect_timeout": 3},
        )
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return engine, None
    except Exception as exc:
        return None, str(exc)


def verificar_freshness(engine) -> Tuple[Optional[str], Optional[str]]:
    """Consulta a função canônica `checar_freshness` (sql/13_controle_build.sql)."""
    if not engine:
        return None, None
    try:
        with engine.connect() as conn:
            status = conn.execute(
                text("SELECT status FROM checar_freshness('fato_venda_medicamento', 24, 48)")
            ).scalar()
        return status, None
    except Exception as exc:
        return None, str(exc)


# -----------------------------------------------------------------------------
# 1. Série Mensal por UF x Classe Terapêutica + Clima (INMET) + População (IBGE)
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def carregar_uf_mes_clima(_engine) -> Tuple[pd.DataFrame, bool, Optional[str]]:
    """Retorna 27 UFs x 12 meses x 2 classes com clima INMET e população IBGE.

    Evita fan-out populacional agregando a população estadual em CTE isolada antes
    do join com as vendas agregadas.
    """
    if _engine:
        sql = """
        WITH pop_uf AS (
            SELECT m.sigla_uf,
                   SUM(p.populacao)::bigint AS populacao_uf
            FROM dim_municipio m
            JOIN ibge_populacao_municipio p
              ON p.id_municipio = m.id_municipio
             AND p.ano = :ano
            WHERE m.is_current = TRUE
            GROUP BY m.sigla_uf
        ),
        vendas_uf_mes AS (
            SELECT m.sigla_uf,
                   m.regiao,
                   t.id_periodo,
                   t.ano,
                   t.mes,
                   t.nome_mes,
                   f.eh_antimicrobiano,
                   COUNT(*)::bigint AS dispensacoes,
                   SUM(f.quantidade_vendida)::numeric(18,2) AS embalagens
            FROM fato_venda_medicamento f
            JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
            JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
            WHERE t.ano = :ano
            GROUP BY m.sigla_uf, m.regiao, t.id_periodo, t.ano, t.mes, t.nome_mes, f.eh_antimicrobiano
        )
        SELECT v.sigla_uf,
               v.regiao,
               v.id_periodo::text AS id_periodo,
               v.ano,
               v.mes,
               v.nome_mes,
               v.eh_antimicrobiano,
               CASE WHEN v.eh_antimicrobiano THEN 'Antimicrobianos' ELSE 'Controlados' END AS classe,
               v.dispensacoes,
               v.embalagens,
               p.populacao_uf,
               ROUND((v.dispensacoes::numeric / NULLIF(p.populacao_uf, 0)) * 1000, 3) AS disp_por_1000_hab,
               ROUND((v.embalagens::numeric / NULLIF(p.populacao_uf, 0)) * 1000, 3) AS emb_por_1000_hab,
               c.temp_media_c::float8 AS temp_media_c,
               c.precipitacao_media_mm::float8 AS precipitacao_media_mm,
               c.qtd_estacoes
        FROM vendas_uf_mes v
        LEFT JOIN pop_uf p
               ON p.sigla_uf = v.sigla_uf
        LEFT JOIN clima_mensal_uf c
               ON c.sigla_uf = v.sigla_uf
              AND c.id_periodo = v.id_periodo
        ORDER BY v.id_periodo, v.sigla_uf, v.eh_antimicrobiano;
        """
        try:
            df = pd.read_sql(text(sql), _engine, params={"ano": ANO_RECORTE})
            if not df.empty:
                df["mes_abrev"] = df["mes"].map(MESES_NOMES)
                return df, False, None
            return mock_uf_mes_clima(), True, "Consulta retornou 0 linhas para o ano de recorte."
        except Exception as exc:
            return mock_uf_mes_clima(), True, str(exc)

    return mock_uf_mes_clima(), True, "Banco de dados inacessível"


def mock_uf_mes_clima() -> pd.DataFrame:
    """Dataset sintético de alta fidelidade (27 UFs x 12 meses x 2 classes) para modo offline."""
    rng = np.random.default_rng(42)
    rows = []

    # Fator pandemia 2020 (queda em abril com isolamento, retomada gradual)
    covid_anti = {1: 1.00, 2: 0.99, 3: 1.06, 4: 0.78, 5: 0.92, 6: 1.03,
                  7: 1.08, 8: 1.04, 9: 0.98, 10: 0.97, 11: 0.99, 12: 1.02}
    covid_ctrl = {1: 0.97, 2: 0.96, 3: 1.10, 4: 0.91, 5: 0.98, 6: 1.02,
                  7: 1.04, 8: 1.05, 9: 1.04, 10: 1.06, 11: 1.07, 12: 1.09}

    for uf, _nome, regiao, pop, t_base, t_amp, chuva_anual, pct_60, _pct_0_14 in UF_META:
        # Nível base per capita influenciado por envelhecimento e acesso urbano
        base_anti_rate = 14.5 + 48.0 * pct_60 + rng.normal(0, 1.1)
        base_ctrl_rate = 7.2 + 52.0 * pct_60 + rng.normal(0, 0.8)

        for mes in range(1, 13):
            # Ciclo térmico: mais frio em jun/jul (mes 6-7)
            fase_frio = np.cos(2 * np.pi * (mes - 1) / 12.0)  # +1 jan, -1 jul
            temp = round(t_base + (t_amp / 2.0) * fase_frio + rng.normal(0, 0.45), 1)

            # Ciclo de chuvas distinto por região brasileira
            if regiao in ("Norte", "Nordeste"):
                # Pico chuvoso fev-mai
                fase_chuva = np.cos(2 * np.pi * (mes - 3.5) / 12.0)
                chuva = max(8.0, (chuva_anual / 12.0) * (1.0 + 0.75 * fase_chuva) + rng.normal(0, 12))
            elif regiao in ("Centro-Oeste", "Sudeste"):
                # Verão chuvoso, inverno seco
                fase_chuva = np.cos(2 * np.pi * (mes - 1.0) / 12.0)
                chuva = max(5.0, (chuva_anual / 12.0) * (1.0 + 0.85 * fase_chuva) + rng.normal(0, 10))
            else:
                # Sul: chuvas distribuídas ao longo do ano
                fase_chuva = np.cos(2 * np.pi * (mes - 10.0) / 12.0)
                chuva = max(45.0, (chuva_anual / 12.0) * (1.0 + 0.25 * fase_chuva) + rng.normal(0, 14))
            chuva = round(float(chuva), 1)

            # Efeito climático nos antimicrobianos:
            # Sul/Sudeste/CO respondem fortemente ao frio; Norte/Nordeste respondem à chuva/umidade
            efeito_frio = max(0.0, (t_base - temp)) * (0.042 if regiao == "Sul" else 0.032 if regiao in ("Sudeste", "Centro-Oeste") else 0.010)
            efeito_chuva = ((chuva - chuva_anual / 12.0) / max(chuva_anual / 12.0, 1.0)) * (0.14 if regiao in ("Norte", "Nordeste") else 0.02)

            taxa_anti = base_anti_rate * covid_anti[mes] * (1.0 + efeito_frio + efeito_chuva + rng.normal(0, 0.02))
            taxa_ctrl = base_ctrl_rate * covid_ctrl[mes] * (1.0 + 0.008 * max(0.0, t_base - temp) + rng.normal(0, 0.015))

            for eh_anti, classe, taxa, fator_emb in (
                (True, "Antimicrobianos", max(taxa_anti, 3.0), 1.65),
                (False, "Controlados", max(taxa_ctrl, 2.0), 1.48),
            ):
                disp = int(round(taxa * pop / 1000.0))
                emb = round(disp * (fator_emb + rng.normal(0, 0.04)), 2)
                rows.append({
                    "sigla_uf": uf,
                    "regiao": regiao,
                    "id_periodo": f"{ANO_RECORTE}{mes:02d}",
                    "ano": ANO_RECORTE,
                    "mes": mes,
                    "nome_mes": MESES_NOMES[mes],
                    "mes_abrev": MESES_NOMES[mes],
                    "eh_antimicrobiano": eh_anti,
                    "classe": classe,
                    "dispensacoes": disp,
                    "embalagens": emb,
                    "populacao_uf": pop,
                    "disp_por_1000_hab": round(disp / pop * 1000.0, 3),
                    "emb_por_1000_hab": round(emb / pop * 1000.0, 3),
                    "temp_media_c": temp,
                    "precipitacao_media_mm": chuva,
                    "qtd_estacoes": int(rng.integers(5, 35)),
                })

    return pd.DataFrame(rows)


# -----------------------------------------------------------------------------
# 2. Estrutura Etária (IBGE Censo 2022) x Antimicrobianos por UF e Mês
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def carregar_etaria_uf_mes(_engine) -> Tuple[pd.DataFrame, pd.DataFrame, bool, Optional[str]]:
    """Cruza `ibge_populacao_faixa_etaria_municipio` com `fato_venda_medicamento`.

    Retorna dois DataFrames:
      - df_pop_etaria_uf: população IBGE Censo 2022 por UF e macro-faixa etária
      - df_disp_etaria_uf_mes: dispensações de antimicrobianos por UF, mês e macro-faixa
    Usa faixas 0-14, 15-29, 30-59 e 60+ para casamento exato com os grupos quinquenais do IBGE.
    """
    if _engine:
        sql_pop = """
        SELECT m.sigla_uf,
               m.regiao,
               CASE
                   WHEN f.faixa_etaria IN ('0 a 4 anos', '5 a 9 anos', '10 a 14 anos') THEN '0-14 (Crianças)'
                   WHEN f.faixa_etaria IN ('15 a 19 anos', '20 a 24 anos', '25 a 29 anos') THEN '15-29 (Jovens)'
                   WHEN f.faixa_etaria IN ('30 a 34 anos', '35 a 39 anos', '40 a 44 anos',
                                           '45 a 49 anos', '50 a 54 anos', '55 a 59 anos') THEN '30-59 (Adultos)'
                   ELSE '60+ (Idosos)'
               END AS macro_faixa,
               SUM(f.populacao)::bigint AS populacao_faixa
        FROM ibge_populacao_faixa_etaria_municipio f
        JOIN dim_municipio m
          ON m.id_municipio = f.id_municipio
         AND m.is_current = TRUE
        GROUP BY m.sigla_uf, m.regiao, macro_faixa
        ORDER BY m.sigla_uf, macro_faixa;
        """
        sql_disp = """
        SELECT m.sigla_uf,
               m.regiao,
               t.id_periodo::text AS id_periodo,
               t.mes,
               CASE
                   WHEN (CASE WHEN f.id_unidade_idade = 2 THEN 0 ELSE f.idade_paciente END) < 15 THEN '0-14 (Crianças)'
                   WHEN (CASE WHEN f.id_unidade_idade = 2 THEN 0 ELSE f.idade_paciente END) < 30 THEN '15-29 (Jovens)'
                   WHEN (CASE WHEN f.id_unidade_idade = 2 THEN 0 ELSE f.idade_paciente END) < 60 THEN '30-59 (Adultos)'
                   ELSE '60+ (Idosos)'
               END AS macro_faixa,
               COUNT(*)::bigint AS dispensacoes,
               SUM(f.quantidade_vendida)::numeric(18,2) AS embalagens
        FROM fato_venda_medicamento f
        JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
        JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
        WHERE f.eh_antimicrobiano = TRUE
          AND f.idade_paciente IS NOT NULL
          AND t.ano = :ano
        GROUP BY m.sigla_uf, m.regiao, t.id_periodo, t.mes, macro_faixa
        ORDER BY t.id_periodo, m.sigla_uf, macro_faixa;
        """
        try:
            df_pop = pd.read_sql(text(sql_pop), _engine)
            df_disp = pd.read_sql(text(sql_disp), _engine, params={"ano": ANO_RECORTE})
            if not df_pop.empty and not df_disp.empty:
                df_disp["mes_abrev"] = df_disp["mes"].map(MESES_NOMES)
                return df_pop, df_disp, False, None
            df_p, df_d = mock_etaria_uf_mes()
            return df_p, df_d, True, "Tabelas etárias retornaram 0 linhas."
        except Exception as exc:
            df_p, df_d = mock_etaria_uf_mes()
            return df_p, df_d, True, str(exc)

    df_p, df_d = mock_etaria_uf_mes()
    return df_p, df_d, True, "Banco de dados inacessível"


def mock_etaria_uf_mes() -> Tuple[pd.DataFrame, pd.DataFrame]:
    rng = np.random.default_rng(108)
    pop_rows = []
    disp_rows = []

    for uf, _nome, regiao, pop, _t_base, _t_amp, _chuva, pct_60, pct_0_14 in UF_META:
        pct_15_29 = round(0.24 - 0.15 * (pct_60 - 0.13), 4)
        pct_30_59 = round(1.0 - pct_0_14 - pct_15_29 - pct_60, 4)
        dist_pop = {
            "0-14 (Crianças)": int(round(pop * pct_0_14)),
            "15-29 (Jovens)": int(round(pop * pct_15_29)),
            "30-59 (Adultos)": int(round(pop * pct_30_59)),
            "60+ (Idosos)": int(round(pop * pct_60)),
        }
        for faixa, p_val in dist_pop.items():
            pop_rows.append({
                "sigla_uf": uf,
                "regiao": regiao,
                "macro_faixa": faixa,
                "populacao_faixa": p_val,
            })

        # Taxa mensal base por 1.000 hab da própria faixa (crianças e idosos têm intensidade maior)
        base_faixa = {
            "0-14 (Crianças)": 22.0,
            "15-29 (Jovens)": 15.5,
            "30-59 (Adultos)": 18.8,
            "60+ (Idosos)": 29.5,
        }
        for mes in range(1, 13):
            frio = -np.cos(2 * np.pi * (mes - 1) / 12.0)  # +1 jul, -1 jan
            covid_drop = 0.78 if mes == 4 else (0.91 if mes == 5 else 1.0)
            for faixa, taxa_base in base_faixa.items():
                # Crianças e idosos sofrem oscilação sazonal mais acentuada no inverno
                sensib = 0.22 if faixa in ("0-14 (Crianças)", "60+ (Idosos)") else 0.10
                if regiao in ("Sul", "Sudeste"):
                    saz = 1.0 + sensib * frio
                else:
                    chuva_f = np.cos(2 * np.pi * (mes - 3.5) / 12.0)
                    saz = 1.0 + (sensib * 0.65) * chuva_f
                taxa = max(2.0, taxa_base * saz * covid_drop * (1.0 + rng.normal(0, 0.03)))
                disp = int(round(taxa * dist_pop[faixa] / 1000.0))
                disp_rows.append({
                    "sigla_uf": uf,
                    "regiao": regiao,
                    "id_periodo": f"{ANO_RECORTE}{mes:02d}",
                    "mes": mes,
                    "mes_abrev": MESES_NOMES[mes],
                    "macro_faixa": faixa,
                    "dispensacoes": disp,
                    "embalagens": round(disp * 1.62, 2),
                })

    return pd.DataFrame(pop_rows), pd.DataFrame(disp_rows)


# -----------------------------------------------------------------------------
# 3. Territorial Municipal Per Capita (IBGE População x SNGPC)
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def carregar_per_capita_municipal(_engine) -> Tuple[pd.DataFrame, bool, Optional[str]]:
    if _engine:
        sql = """
        SELECT m.id_municipio,
               m.nome_municipio,
               m.sigla_uf,
               m.regiao,
               p.populacao,
               COUNT(*)::bigint AS dispensacoes,
               SUM(CASE WHEN f.eh_antimicrobiano THEN 1 ELSE 0 END)::bigint AS disp_antimicrobianos,
               SUM(CASE WHEN NOT f.eh_antimicrobiano THEN 1 ELSE 0 END)::bigint AS disp_controlados,
               SUM(f.quantidade_vendida)::numeric(18,2) AS embalagens,
               ROUND((COUNT(*)::numeric / NULLIF(p.populacao, 0)) * 1000, 2) AS dispensacoes_por_1000_hab
        FROM fato_venda_medicamento f
        JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
        JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
        LEFT JOIN ibge_populacao_municipio p
               ON p.id_municipio = m.id_municipio
              AND p.ano = :ano
        WHERE t.ano = :ano
        GROUP BY m.id_municipio, m.nome_municipio, m.sigla_uf, m.regiao, p.populacao;
        """
        try:
            df = pd.read_sql(text(sql), _engine, params={"ano": ANO_RECORTE})
            if not df.empty:
                return df, False, None
            return mock_per_capita_municipal(), True, "Consulta municipal retornou 0 linhas."
        except Exception as exc:
            return mock_per_capita_municipal(), True, str(exc)

    return mock_per_capita_municipal(), True, "Banco de dados inacessível"


def mock_per_capita_municipal() -> pd.DataFrame:
    cidades = [
        ("São Paulo", "SP", "Sudeste", 12_325_232, 3_680_000),
        ("Rio de Janeiro", "RJ", "Sudeste", 6_747_815, 2_120_000),
        ("Brasília", "DF", "Centro-Oeste", 3_055_149, 1_045_000),
        ("Salvador", "BA", "Nordeste", 2_886_698, 720_000),
        ("Fortaleza", "CE", "Nordeste", 2_686_612, 745_000),
        ("Belo Horizonte", "MG", "Sudeste", 2_521_564, 985_000),
        ("Manaus", "AM", "Norte", 2_219_580, 495_000),
        ("Curitiba", "PR", "Sul", 1_948_626, 845_000),
        ("Recife", "PE", "Nordeste", 1_653_461, 515_000),
        ("Goiânia", "GO", "Centro-Oeste", 1_536_097, 560_000),
        ("Porto Alegre", "RS", "Sul", 1_488_252, 710_000),
        ("Belém", "PA", "Norte", 1_499_641, 350_000),
        ("Campinas", "SP", "Sudeste", 1_213_792, 510_000),
        ("Ribeirão Preto", "SP", "Sudeste", 711_825, 342_000),
        ("Uberlândia", "MG", "Sudeste", 699_097, 325_000),
        ("Sorocaba", "SP", "Sudeste", 687_357, 288_000),
        ("Londrina", "PR", "Sul", 575_377, 296_000),
        ("Caxias do Sul", "RS", "Sul", 517_451, 275_000),
        ("Florianópolis", "SC", "Sul", 508_826, 282_000),
        ("Maringá", "PR", "Sul", 430_157, 241_000),
        ("Blumenau", "SC", "Sul", 361_855, 198_000),
        ("Passo Fundo", "RS", "Sul", 204_722, 122_000),
        ("Balneário Camboriú", "SC", "Sul", 145_796, 94_000),
        ("Indaiatuba", "SP", "Sudeste", 256_223, 118_000),
        ("Sinop", "MT", "Centro-Oeste", 146_005, 58_000),
        ("Juazeiro do Norte", "CE", "Nordeste", 276_264, 82_000),
        ("Santarém", "PA", "Norte", 306_480, 62_000),
        ("Lages", "SC", "Sul", 157_349, 76_000),
        ("Pouso Alegre", "MG", "Sudeste", 152_549, 78_000),
        ("Pato Branco", "PR", "Sul", 83_843, 47_500),
        ("Gramado", "RS", "Sul", 36_555, 22_800),
        ("Araxá", "MG", "Sudeste", 107_337, 46_200),
        ("Barreiras", "BA", "Nordeste", 156_975, 44_500),
        ("Imperatriz", "MA", "Nordeste", 259_337, 61_000),
        ("Dourados", "MS", "Centro-Oeste", 225_495, 86_000),
        ("Rio Branco", "AC", "Norte", 413_418, 92_000),
        ("Boa Vista", "RR", "Norte", 419_652, 88_000),
        ("Macapá", "AP", "Norte", 512_902, 102_000),
        ("Palmas", "TO", "Norte", 306_296, 96_000),
        ("Porto Velho", "RO", "Norte", 539_354, 134_000),
    ]
    rows = []
    for idx, (nome, uf, reg, pop, disp) in enumerate(cidades, start=1):
        disp_anti = int(round(disp * 0.64))
        rows.append({
            "id_municipio": idx,
            "nome_municipio": nome,
            "sigla_uf": uf,
            "regiao": reg,
            "populacao": pop,
            "dispensacoes": disp,
            "disp_antimicrobianos": disp_anti,
            "disp_controlados": disp - disp_anti,
            "embalagens": round(disp * 1.58, 2),
            "dispensacoes_por_1000_hab": round(disp / pop * 1000.0, 2),
        })
    return pd.DataFrame(rows)


# -----------------------------------------------------------------------------
# 4. Diagnósticos Clínicos (DATASUS CID-10) x Tempo, Clima e Estados
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def carregar_cid10_uf_mes(_engine) -> Tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, bool, Optional[str]]:
    """Retorna:
      - df_cap_uf_mes: capítulos clínicos CID-10 por UF e mês
      - df_top_cid: Top 15 códigos CID-10 por UF/região
      - df_cobertura: taxa de preenchimento de CID-10 nos antimicrobianos por UF
    """
    if _engine:
        sql_cap = """
        SELECT m.sigla_uf,
               m.regiao,
               t.id_periodo::text AS id_periodo,
               t.mes,
               CASE LEFT(UPPER(TRIM(f.codigo_cid10)), 1)
                   WHEN 'J' THEN 'J - Aparelho Respiratório'
                   WHEN 'N' THEN 'N - Aparelho Geniturinário'
                   WHEN 'K' THEN 'K - Aparelho Digestivo / Odonto'
                   WHEN 'L' THEN 'L - Pele e Tecido Subcutâneo'
                   WHEN 'H' THEN 'H - Ouvido e Olho'
                   WHEN 'A' THEN 'A/B - Infecciosas e Parasitárias'
                   WHEN 'B' THEN 'A/B - Infecciosas e Parasitárias'
                   ELSE 'Outros Capítulos CID-10'
               END AS capitulo_cid,
               COUNT(*)::bigint AS dispensacoes,
               SUM(f.quantidade_vendida)::numeric(18,2) AS embalagens
        FROM fato_venda_medicamento f
        JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
        JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
        WHERE f.eh_antimicrobiano = TRUE
          AND f.codigo_cid10 IS NOT NULL
          AND TRIM(f.codigo_cid10) <> ''
          AND t.ano = :ano
        GROUP BY m.sigla_uf, m.regiao, t.id_periodo, t.mes, capitulo_cid
        ORDER BY t.id_periodo, m.sigla_uf;
        """
        sql_top = """
        SELECT m.sigla_uf,
               m.regiao,
               UPPER(TRIM(f.codigo_cid10)) AS cid_codigo,
               COALESCE(c.descricao_abreviada, c.descricao, 'Código não catalogado') AS cid_descricao,
               COUNT(*)::bigint AS dispensacoes,
               SUM(f.quantidade_vendida)::numeric(18,2) AS embalagens
        FROM fato_venda_medicamento f
        JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
        JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
        LEFT JOIN cid10 c    ON c.codigo = UPPER(TRIM(f.codigo_cid10))
        WHERE f.eh_antimicrobiano = TRUE
          AND f.codigo_cid10 IS NOT NULL
          AND TRIM(f.codigo_cid10) <> ''
          AND t.ano = :ano
        GROUP BY m.sigla_uf, m.regiao, cid_codigo, cid_descricao;
        """
        sql_cov = """
        SELECT m.sigla_uf,
               m.regiao,
               COUNT(*)::bigint AS total_antimicrobianos,
               COUNT(NULLIF(TRIM(f.codigo_cid10), ''))::bigint AS com_cid10
        FROM fato_venda_medicamento f
        JOIN dim_municipio m ON m.sk_municipio = f.sk_municipio
        JOIN dim_tempo t     ON t.sk_tempo = f.sk_tempo
        WHERE f.eh_antimicrobiano = TRUE
          AND t.ano = :ano
        GROUP BY m.sigla_uf, m.regiao;
        """
        try:
            df_cap = pd.read_sql(text(sql_cap), _engine, params={"ano": ANO_RECORTE})
            df_top = pd.read_sql(text(sql_top), _engine, params={"ano": ANO_RECORTE})
            df_cov = pd.read_sql(text(sql_cov), _engine, params={"ano": ANO_RECORTE})
            if not df_cap.empty:
                df_cap["mes_abrev"] = df_cap["mes"].map(MESES_NOMES)
                return df_cap, df_top, df_cov, False, None
            c1, c2, c3 = mock_cid10_uf_mes()
            return c1, c2, c3, True, "Consulta CID-10 retornou 0 linhas."
        except Exception as exc:
            c1, c2, c3 = mock_cid10_uf_mes()
            return c1, c2, c3, True, str(exc)

    c1, c2, c3 = mock_cid10_uf_mes()
    return c1, c2, c3, True, "Banco de dados inacessível"


def mock_cid10_uf_mes() -> Tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    rng = np.random.default_rng(77)
    capitulos = [
        ("J - Aparelho Respiratório", 0.44),
        ("N - Aparelho Geniturinário", 0.18),
        ("K - Aparelho Digestivo / Odonto", 0.13),
        ("L - Pele e Tecido Subcutâneo", 0.10),
        ("H - Ouvido e Olho", 0.08),
        ("A/B - Infecciosas e Parasitárias", 0.07),
    ]
    top_codes = [
        ("J01", "Sinusite aguda", 0.16),
        ("J03", "Amigdalite aguda", 0.14),
        ("J06", "Infecções agudas das vias aéreas superiores", 0.12),
        ("N390", "Infecção do trato urinário (localização NE)", 0.12),
        ("J02", "Faringite aguda", 0.10),
        ("K04", "Doenças da polpa e tecidos periapicais", 0.09),
        ("J20", "Bronquite aguda", 0.07),
        ("L03", "Celulite (infecção bacteriana de pele)", 0.07),
        ("H66", "Otite média supurativa e não especificada", 0.07),
        ("J18", "Pneumonia por micro-organismo NE", 0.06),
    ]

    cap_rows, top_rows, cov_rows = [], [], []
    for uf, _nome, regiao, pop, _t_base, _t_amp, _chuva, _pct_60, _pct_0_14 in UF_META:
        total_anti = int(pop * 0.24)
        taxa_cov = float(rng.uniform(0.0045, 0.0085))
        com_cid = int(total_anti * taxa_cov)
        cov_rows.append({
            "sigla_uf": uf,
            "regiao": regiao,
            "total_antimicrobianos": total_anti,
            "com_cid10": com_cid,
        })

        # Sul/Sudeste têm maior fatia de respiratório (J); Norte/NE maior fatia A/B e pele
        resp_boost = 1.22 if regiao == "Sul" else 1.10 if regiao == "Sudeste" else 0.88 if regiao == "Norte" else 0.96

        for mes in range(1, 13):
            frio = -np.cos(2 * np.pi * (mes - 1) / 12.0)  # +1 jul
            covid = 0.78 if mes == 4 else 1.0
            for cap, peso in capitulos:
                if cap.startswith("J"):
                    fator = resp_boost * (1.0 + (0.38 if regiao in ("Sul", "Sudeste") else 0.14) * frio)
                elif cap.startswith("A/B"):
                    chuva_f = np.cos(2 * np.pi * (mes - 3.5) / 12.0)
                    fator = (1.25 if regiao in ("Norte", "Nordeste") else 0.85) * (1.0 + 0.20 * chuva_f)
                else:
                    fator = 1.0 + rng.normal(0, 0.04)
                disp = max(5, int(round((com_cid / 12.0) * peso * fator * covid)))
                cap_rows.append({
                    "sigla_uf": uf,
                    "regiao": regiao,
                    "id_periodo": f"{ANO_RECORTE}{mes:02d}",
                    "mes": mes,
                    "mes_abrev": MESES_NOMES[mes],
                    "capitulo_cid": cap,
                    "dispensacoes": disp,
                    "embalagens": round(disp * 1.55, 2),
                })

        for code, desc, peso in top_codes:
            boost = resp_boost if code.startswith("J") else 1.0
            disp = max(10, int(round(com_cid * peso * boost * (1.0 + rng.normal(0, 0.05)))))
            top_rows.append({
                "sigla_uf": uf,
                "regiao": regiao,
                "cid_codigo": code,
                "cid_descricao": desc,
                "dispensacoes": disp,
                "embalagens": round(disp * 1.55, 2),
            })

    return pd.DataFrame(cap_rows), pd.DataFrame(top_rows), pd.DataFrame(cov_rows)
