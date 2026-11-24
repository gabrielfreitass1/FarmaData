"""Motor estatístico e de correlações multi-base do painel FarmaData.

Responsável por calcular correlações temporais (ao longo dos 12 meses por UF)
e transversais (entre os 27 estados), índice de sazonalidade (Base 100),
variação mês a mês (MoM %) e índice de sobrerrepresentação etária.
"""

from __future__ import annotations

from typing import Dict, List, Tuple

import numpy as np
import pandas as pd


def calcular_pearson(s1: pd.Series, s2: pd.Series) -> float:
    """Calcula a correlação de Pearson com proteção contra NaN ou variância zero."""
    df_tmp = pd.DataFrame({"a": pd.to_numeric(s1, errors="coerce"),
                           "b": pd.to_numeric(s2, errors="coerce")}).dropna()
    if len(df_tmp) < 3:
        return float("nan")
    if df_tmp["a"].nunique() < 2 or df_tmp["b"].nunique() < 2:
        return float("nan")
    return float(df_tmp["a"].corr(df_tmp["b"]))


def classificar_correlacao(r: float) -> Tuple[str, str]:
    """Retorna (força, sentido) legíveis para um coeficiente de Pearson."""
    if pd.isna(r):
        return "insuficiente", "sem dados suficientes"
    abs_r = abs(r)
    if abs_r >= 0.70:
        forca = "forte"
    elif abs_r >= 0.40:
        forca = "moderada"
    elif abs_r >= 0.20:
        forca = "fraca"
    else:
        forca = "muito fraca"
    sentido = "positiva" if r >= 0 else "negativa"
    return forca, sentido


def preparar_serie_estadual_mensal(
    df_uf_mes: pd.DataFrame,
    classe: str = "Todas",
    metrica_col: str = "disp_por_1000_hab",
) -> pd.DataFrame:
    """Agrega por UF x Mês (respeitando filtro de classe) e calcula Base 100 e MoM %."""
    df = df_uf_mes.copy()
    if classe != "Todas":
        df = df[df["classe"] == classe]

    agg = (
        df.groupby(["sigla_uf", "regiao", "id_periodo", "mes", "mes_abrev"], as_index=False)
        .agg(
            dispensacoes=("dispensacoes", "sum"),
            embalagens=("embalagens", "sum"),
            populacao_uf=("populacao_uf", "first"),
            temp_media_c=("temp_media_c", "mean"),
            precipitacao_media_mm=("precipitacao_media_mm", "mean"),
        )
    )
    agg["disp_por_1000_hab"] = np.where(
        agg["populacao_uf"] > 0,
        agg["dispensacoes"] / agg["populacao_uf"] * 1000.0,
        np.nan,
    )
    agg["emb_por_1000_hab"] = np.where(
        agg["populacao_uf"] > 0,
        agg["embalagens"] / agg["populacao_uf"] * 1000.0,
        np.nan,
    )

    agg = agg.sort_values(["sigla_uf", "mes"]).reset_index(drop=True)
    media_uf = agg.groupby("sigla_uf")[metrica_col].transform("mean")
    agg["indice_sazonal"] = np.where(media_uf > 0, (agg[metrica_col] / media_uf) * 100.0, np.nan)
    agg["variacao_mom_pct"] = agg.groupby("sigla_uf")[metrica_col].pct_change() * 100.0
    return agg


def calcular_correlacoes_climaticas_por_uf(
    df_uf_mes: pd.DataFrame,
    metrica_col: str = "disp_por_1000_hab",
) -> pd.DataFrame:
    """Calcula, para cada uma das 27 UFs, a correlação mensal com temperatura e precipitação.

    Separa Antimicrobianos e Controlados para contrastar sensibilidade climática entre classes.
    """
    rows: List[Dict] = []
    for (uf, regiao), grp_uf in df_uf_mes.groupby(["sigla_uf", "regiao"]):
        anti = grp_uf[grp_uf["eh_antimicrobiano"]].sort_values("mes")
        ctrl = grp_uf[~grp_uf["eh_antimicrobiano"]].sort_values("mes")

        r_temp_anti = calcular_pearson(anti["temp_media_c"], anti[metrica_col])
        r_chuva_anti = calcular_pearson(anti["precipitacao_media_mm"], anti[metrica_col])
        r_temp_ctrl = calcular_pearson(ctrl["temp_media_c"], ctrl[metrica_col])
        r_chuva_ctrl = calcular_pearson(ctrl["precipitacao_media_mm"], ctrl[metrica_col])

        temps = anti["temp_media_c"].dropna()
        chuvas = anti["precipitacao_media_mm"].dropna()
        vals_anti = anti[metrica_col].dropna()

        amp_termica = float(temps.max() - temps.min()) if len(temps) >= 2 else float("nan")
        cv_anti = (
            float(vals_anti.std() / vals_anti.mean() * 100.0)
            if len(vals_anti) >= 2 and vals_anti.mean() > 0
            else float("nan")
        )
        mes_pico = (
            anti.loc[anti[metrica_col].idxmax(), "mes_abrev"]
            if not anti.empty and anti[metrica_col].notna().any()
            else "—"
        )

        # Classifica o vetor climático dominante no estado
        if pd.isna(r_temp_anti) and pd.isna(r_chuva_anti):
            fator_dom = "Sem dados climáticos"
        else:
            rt = 0.0 if pd.isna(r_temp_anti) else float(r_temp_anti)
            rc = 0.0 if pd.isna(r_chuva_anti) else float(r_chuva_anti)
            if abs(rt) >= abs(rc):
                fator_dom = "Frio (Temp. inversa)" if rt < 0 else "Calor (Temp. direta)"
            else:
                fator_dom = "Chuva (Precip. direta)" if rc > 0 else "Seca (Precip. inversa)"

        rows.append({
            "sigla_uf": uf,
            "regiao": regiao,
            "populacao_uf": float(anti["populacao_uf"].iloc[0]) if not anti.empty else np.nan,
            "temp_media_anual_c": float(temps.mean()) if len(temps) else np.nan,
            "amplitude_termica_c": amp_termica,
            "precipitacao_total_mm": float(chuvas.sum()) if len(chuvas) else np.nan,
            "taxa_anual_anti": float(vals_anti.sum()) if len(vals_anti) else np.nan,
            "taxa_anual_ctrl": float(ctrl[metrica_col].sum()) if not ctrl.empty else np.nan,
            "cv_sazonal_anti_pct": cv_anti,
            "mes_pico_anti": mes_pico,
            "r_temp_anti": r_temp_anti,
            "r_chuva_anti": r_chuva_anti,
            "r_temp_ctrl": r_temp_ctrl,
            "r_chuva_ctrl": r_chuva_ctrl,
            "fator_climatico_dominante": fator_dom,
        })

    return pd.DataFrame(rows).sort_values("r_temp_anti", ascending=True).reset_index(drop=True)


def construir_tabela_indicadores_estaduais(
    df_uf_mes: pd.DataFrame,
    df_pop_etaria: pd.DataFrame,
    df_cid_cap: pd.DataFrame,
    metrica_col: str = "disp_por_1000_hab",
) -> pd.DataFrame:
    """Consolida 1 linha por UF cruzando SNGPC + IBGE População + IBGE Etária + INMET + CID-10."""
    base = calcular_correlacoes_climaticas_por_uf(df_uf_mes, metrica_col=metrica_col)
    base["taxa_anual_total"] = base["taxa_anual_anti"].fillna(0) + base["taxa_anual_ctrl"].fillna(0)

    # Estrutura etária por UF (IBGE Censo 2022)
    if not df_pop_etaria.empty:
        piv_et = df_pop_etaria.pivot_table(
            index="sigla_uf",
            columns="macro_faixa",
            values="populacao_faixa",
            aggfunc="sum",
            fill_value=0,
        )
        tot_et = piv_et.sum(axis=1).replace(0, np.nan)
        et_uf = pd.DataFrame({
            "sigla_uf": piv_et.index,
            "pct_criancas_0_14": (piv_et.get("0-14 (Crianças)", 0) / tot_et * 100.0).values,
            "pct_idosos_60_mais": (piv_et.get("60+ (Idosos)", 0) / tot_et * 100.0).values,
        })
        base = base.merge(et_uf, on="sigla_uf", how="left")
    else:
        base["pct_criancas_0_14"] = np.nan
        base["pct_idosos_60_mais"] = np.nan

    # Proporção de CID-10 respiratório (Capítulo J) por UF
    if not df_cid_cap.empty:
        cid_tot = df_cid_cap.groupby("sigla_uf")["dispensacoes"].sum()
        cid_j = (
            df_cid_cap[df_cid_cap["capitulo_cid"].str.startswith("J")]
            .groupby("sigla_uf")["dispensacoes"]
            .sum()
        )
        cid_uf = pd.DataFrame({
            "sigla_uf": cid_tot.index,
            "pct_cid_respiratorio": (cid_j.reindex(cid_tot.index, fill_value=0) / cid_tot.replace(0, np.nan) * 100.0).values,
        })
        base = base.merge(cid_uf, on="sigla_uf", how="left")
    else:
        base["pct_cid_respiratorio"] = np.nan

    return base


def calcular_matriz_correlacao_multibase(df_indicadores_uf: pd.DataFrame) -> pd.DataFrame:
    """Retorna matriz de correlação de Pearson entre indicadores auxiliares (linhas)
    e métricas de dispensação/sazonalidade (colunas) nos 27 estados.
    """
    aux_cols = {
        "temp_media_anual_c": "Temp. Média Anual (°C) [INMET]",
        "amplitude_termica_c": "Amplitude Térmica (°C) [INMET]",
        "precipitacao_total_mm": "Precipitação Anual (mm) [INMET]",
        "pct_idosos_60_mais": "% População 60+ [IBGE Censo]",
        "pct_criancas_0_14": "% População 0–14 [IBGE Censo]",
        "populacao_uf": "População Total [IBGE]",
        "pct_cid_respiratorio": "% CID-10 Respiratório [DATASUS]",
    }
    disp_cols = {
        "taxa_anual_total": "Dispensação Total / 1k hab",
        "taxa_anual_anti": "Antimicrobianos / 1k hab",
        "taxa_anual_ctrl": "Controlados / 1k hab",
        "cv_sazonal_anti_pct": "Volatilidade Sazonal (CV%)",
        "r_temp_anti": "Sensib. ao Clima (r Temp.)",
    }

    mat = pd.DataFrame(index=list(aux_cols.values()), columns=list(disp_cols.values()), dtype=float)
    for col_a, lbl_a in aux_cols.items():
        for col_d, lbl_d in disp_cols.items():
            if col_a in df_indicadores_uf.columns and col_d in df_indicadores_uf.columns:
                mat.loc[lbl_a, lbl_d] = round(
                    calcular_pearson(df_indicadores_uf[col_a], df_indicadores_uf[col_d]), 2
                )
    return mat


def extrair_principais_achados(mat_corr: pd.DataFrame, top_n: int = 4) -> List[Dict]:
    """Extrai as correlações mais expressivas (por |r|) da matriz multi-base."""
    pares = []
    for aux_lbl in mat_corr.index:
        for disp_lbl in mat_corr.columns:
            val = mat_corr.loc[aux_lbl, disp_lbl]
            if pd.notna(val):
                forca, sentido = classificar_correlacao(float(val))
                pares.append({
                    "auxiliar": aux_lbl,
                    "metrica": disp_lbl,
                    "r": float(val),
                    "abs_r": abs(float(val)),
                    "forca": forca,
                    "sentido": sentido,
                })
    pares.sort(key=lambda x: x["abs_r"], reverse=True)
    return pares[:top_n]


def calcular_intensidade_etaria(
    df_pop_etaria: pd.DataFrame,
    df_disp_etaria: pd.DataFrame,
) -> pd.DataFrame:
    """Calcula taxa por 1.000 hab da faixa e Índice de Sobrerrepresentação (% disp / % pop)."""
    pop_uf = df_pop_etaria.groupby(["sigla_uf", "regiao", "macro_faixa"], as_index=False)["populacao_faixa"].sum()
    disp_uf = df_disp_etaria.groupby(["sigla_uf", "regiao", "macro_faixa"], as_index=False)["dispensacoes"].sum()

    merged = pop_uf.merge(disp_uf, on=["sigla_uf", "regiao", "macro_faixa"], how="inner")
    tot_pop = merged.groupby("sigla_uf")["populacao_faixa"].transform("sum")
    tot_disp = merged.groupby("sigla_uf")["dispensacoes"].transform("sum")

    merged["pct_populacao"] = np.where(tot_pop > 0, merged["populacao_faixa"] / tot_pop * 100.0, np.nan)
    merged["pct_dispensacoes"] = np.where(tot_disp > 0, merged["dispensacoes"] / tot_disp * 100.0, np.nan)
    merged["taxa_por_1000_faixa"] = np.where(
        merged["populacao_faixa"] > 0,
        merged["dispensacoes"] / merged["populacao_faixa"] * 1000.0,
        np.nan,
    )
    merged["indice_sobrerrepresentacao"] = np.where(
        merged["pct_populacao"] > 0,
        merged["pct_dispensacoes"] / merged["pct_populacao"],
        np.nan,
    )
    return merged


def classificar_porte_municipal(populacao: pd.Series) -> pd.Series:
    """Classifica municípios por porte populacional IBGE."""
    bins = [0, 50_000, 200_000, 1_000_000, float("inf")]
    labels = ["Pequeno (<50k)", "Médio (50k–200k)", "Grande (200k–1M)", "Metrópole (>1M)"]
    return pd.cut(populacao, bins=bins, labels=labels, right=True)
