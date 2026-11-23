"""Painel Analítico FarmaData — Correlações Multi-Base de Dispensação de Medicamentos.

Cruza o modelo dimensional do SNGPC/Anvisa (`fato_venda_medicamento`, `dim_municipio`,
`dim_tempo`) com todas as bases auxiliares do projeto:
  - IBGE População por Município (`ibge_populacao_municipio`)
  - INMET Clima Mensal por UF (`clima_mensal_uf`: temperatura e precipitação)
  - IBGE Estrutura Etária (`ibge_populacao_faixa_etaria_municipio`, Censo 2022)
  - DATASUS CID-10 (`cid10`)

Objetivo: evidenciar como fatores climáticos, demográficos, populacionais e clínicos
correlacionam-se com a variação da dispensação ao longo do tempo e entre os 27 estados.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

from analytics import (
    calcular_correlacoes_climaticas_por_uf,
    calcular_intensidade_etaria,
    calcular_matriz_correlacao_multibase,
    calcular_pearson,
    classificar_correlacao,
    classificar_porte_municipal,
    construir_tabela_indicadores_estaduais,
    extrair_principais_achados,
    preparar_serie_estadual_mensal,
)
from queries import (
    ANO_RECORTE,
    POP_MIN_PER_CAPITA,
    carregar_cid10_uf_mes,
    carregar_etaria_uf_mes,
    carregar_per_capita_municipal,
    carregar_uf_mes_clima,
    get_engine,
    verificar_freshness,
)

# -----------------------------------------------------------------------------
# Configuração da página e paleta consistente por região
# -----------------------------------------------------------------------------
st.set_page_config(
    page_title="FarmaData — Correlações Multi-Base",
    page_icon="💊",
    layout="wide",
    initial_sidebar_state="expanded",
)

REGIAO_CORES = {
    "Norte": "#2A9D8F",
    "Nordeste": "#E76F51",
    "Centro-Oeste": "#E9C46A",
    "Sudeste": "#264653",
    "Sul": "#457B9D",
}

ORDEM_FAIXAS = ["0-14 (Crianças)", "15-29 (Jovens)", "30-59 (Adultos)", "60+ (Idosos)"]


def scatter_com_tendencia(df: pd.DataFrame, **kwargs) -> go.Figure:
    """Cria gráfico de dispersão com OLS e fallback seguro caso statsmodels falhe."""
    try:
        return px.scatter(df, trendline="ols", **kwargs)
    except Exception:
        return px.scatter(df, **kwargs)


def fmt_int(n: float) -> str:
    if pd.isna(n):
        return "—"
    return f"{n:,.0f}".replace(",", ".")


def fmt_r(r: float) -> str:
    return "—" if pd.isna(r) else f"{r:+.2f}"


# -----------------------------------------------------------------------------
# Conexão, Freshness e Carga de Dados (em cache)
# -----------------------------------------------------------------------------
engine, db_conn_error = get_engine()

if engine:
    status_fresh, err_fresh = verificar_freshness(engine)
    if status_fresh == "ERRO":
        st.error(
            "🚨 **SLA de Freshness violado (ERRO):** A tabela `fato_venda_medicamento` "
            "está desatualizada há mais de 48h ou nunca foi construída."
        )
        continuar_demo = st.checkbox(
            "Ignorar bloqueio de freshness e visualizar o painel em Modo Demonstração (dados simulados)",
            value=False,
        )
        if not continuar_demo:
            st.info(
                "Para popular o banco real e construir o modelo dimensional no PowerShell:\n"
                "```powershell\n"
                "docker compose up carga\n"
                "docker compose exec -T db psql -U postgres -d farmadata -v ON_ERROR_STOP=1 -c \"SELECT * FROM aplicar_scd2_municipio(); SELECT carregar_fato_venda_medicamento() AS linhas_carregadas;\"\n"
                "```"
            )
            st.stop()
        engine = None
        db_conn_error = "Freshness em estado ERRO (fato_venda_medicamento vazia ou não construída)."
    elif status_fresh == "WARN":
        st.warning(
            "⚠️ **Aviso de Freshness (WARN):** Carga pendente há mais de 24h sem "
            "reconstrução da `fato_venda_medicamento`."
        )
    elif err_fresh:
        st.sidebar.caption(f"Freshness indisponível: {err_fresh}")

df_uf_mes, mock_uf, err_uf = carregar_uf_mes_clima(engine)
df_pop_etaria, df_disp_etaria, mock_et, err_et = carregar_etaria_uf_mes(engine)
df_mun, mock_mun, err_mun = carregar_per_capita_municipal(engine)
df_cid_cap, df_cid_top, df_cid_cov, mock_cid, err_cid = carregar_cid10_uf_mes(engine)

modo_demo = any([mock_uf, mock_et, mock_mun, mock_cid])

# -----------------------------------------------------------------------------
# Barra Lateral — Filtros Globais
# -----------------------------------------------------------------------------
st.sidebar.header("🎯 Filtros Analíticos")

regioes_disponiveis = sorted(df_uf_mes["regiao"].dropna().unique().tolist())
regioes_sel = st.sidebar.multiselect(
    "Regiões:",
    options=regioes_disponiveis,
    default=regioes_disponiveis,
)

ufs_por_regiao = sorted(
    df_uf_mes[df_uf_mes["regiao"].isin(regioes_sel)]["sigla_uf"].unique().tolist()
)
uf_foco = st.sidebar.selectbox(
    "Estado em foco (séries detalhadas):",
    options=["TODAS"] + ufs_por_regiao,
    index=0,
    help="Filtra gráficos temporais detalhados; os comparativos interestaduais mantêm as regiões selecionadas.",
)

classe_sel = st.sidebar.radio(
    "Classe terapêutica:",
    options=["Todas", "Antimicrobianos", "Controlados"],
    index=0,
)

metrica_opcao = st.sidebar.radio(
    "Métrica normalizada:",
    options=["Dispensações / 1.000 hab", "Embalagens / 1.000 hab"],
    index=0,
    help="Dispensações (linhas de venda) evitam distorções de unidades mistas (caixas vs frascos).",
)
metrica_col = "disp_por_1000_hab" if "Dispensações" in metrica_opcao else "emb_por_1000_hab"
metrica_vol_col = "dispensacoes" if "Dispensações" in metrica_opcao else "embalagens"

st.sidebar.markdown("---")
st.sidebar.caption(
    f"**Recorte:** {ANO_RECORTE} | **Fonte:** "
    + ("Modo Demonstração (DB offline)" if modo_demo else "PostgreSQL Star Schema")
)

# Recorte por regiões selecionadas
df_uf_mes_reg = df_uf_mes[df_uf_mes["regiao"].isin(regioes_sel)].copy()
df_pop_etaria_reg = df_pop_etaria[df_pop_etaria["regiao"].isin(regioes_sel)].copy()
df_disp_etaria_reg = df_disp_etaria[df_disp_etaria["regiao"].isin(regioes_sel)].copy()
df_mun_reg = df_mun[df_mun["regiao"].isin(regioes_sel)].copy()
df_cid_cap_reg = df_cid_cap[df_cid_cap["regiao"].isin(regioes_sel)].copy()
df_cid_top_reg = df_cid_top[df_cid_top["regiao"].isin(regioes_sel)].copy()
df_cid_cov_reg = df_cid_cov[df_cid_cov["regiao"].isin(regioes_sel)].copy()

if df_uf_mes_reg.empty:
    st.warning("Selecione pelo menos uma região na barra lateral para visualizar os dados.")
    st.stop()

# Cálculos consolidados
df_serie_uf = preparar_serie_estadual_mensal(df_uf_mes_reg, classe=classe_sel, metrica_col=metrica_col)
df_indicadores_uf = construir_tabela_indicadores_estaduais(
    df_uf_mes_reg, df_pop_etaria_reg, df_cid_cap_reg, metrica_col=metrica_col
)
mat_corr = calcular_matriz_correlacao_multibase(df_indicadores_uf)
top_achados = extrair_principais_achados(mat_corr, top_n=4)

# -----------------------------------------------------------------------------
# Cabeçalho Principal
# -----------------------------------------------------------------------------
st.title("💊 FarmaData — Correlações Multi-Base de Dispensação")
st.markdown(
    "> **Objetivo Analítico:** Correlacionar a variação da dispensação de medicamentos "
    f"ao longo de **{ANO_RECORTE}** e entre os **estados brasileiros** com as bases auxiliares "
    "**IBGE População**, **IBGE Estrutura Etária (Censo 2022)**, **INMET Clima (Temperatura e Precipitação)** "
    "e **DATASUS CID-10**."
)

if modo_demo:
    erros = [e for e in (err_uf, err_et, err_mun, err_cid, db_conn_error) if e]
    st.warning(
        "⚠️ **Modo Demonstração ativo:** Banco PostgreSQL indisponível no momento. "
        "Exibindo conjunto simulado de alta fidelidade (27 UFs × 12 meses) com a mesma estrutura "
        "das consultas SQL do Star Schema."
    )
    if erros:
        with st.expander("Ver detalhes técnicos da conexão"):
            st.code("\n".join(dict.fromkeys(erros)), language="text")

# -----------------------------------------------------------------------------
# Abas Temáticas (5 painéis integrados)
# -----------------------------------------------------------------------------
tab1, tab2, tab3, tab4, tab5 = st.tabs([
    "📊 1. Panorama & Matriz de Correlações",
    "🌡️ 2. Clima × Tempo & Estados (INMET)",
    "👥 3. Estrutura Etária × Consumo (IBGE)",
    "📍 4. Escala Populacional & Municípios (IBGE)",
    "🩺 5. Diagnósticos CID-10 × Sazonalidade",
])

# =============================================================================
# ABA 1: PANORAMA & MATRIZ DE CORRELAÇÕES MULTI-BASE
# =============================================================================
with tab1:
    st.subheader("Síntese Interestadual: Como as Bases Auxiliares Explicam a Dispensação")

    # KPIs Executivos
    total_disp = df_serie_uf[metrica_vol_col].sum()
    pop_total = df_indicadores_uf["populacao_uf"].sum()
    taxa_media_anual = (total_disp / pop_total * 1000.0) if pop_total > 0 else np.nan
    uf_maior_taxa = (
        df_indicadores_uf.loc[df_indicadores_uf["taxa_anual_total"].idxmax()]
        if df_indicadores_uf["taxa_anual_total"].notna().any()
        else None
    )
    uf_maior_cv = (
        df_indicadores_uf.loc[df_indicadores_uf["cv_sazonal_anti_pct"].idxmax()]
        if df_indicadores_uf["cv_sazonal_anti_pct"].notna().any()
        else None
    )
    achado_top = top_achados[0] if top_achados else None

    k1, k2, k3, k4 = st.columns(4)
    k1.metric(
        f"Total ({classe_sel})",
        fmt_int(total_disp),
        delta=f"{taxa_media_anual:.1f} / 1.000 hab no ano" if pd.notna(taxa_media_anual) else None,
        delta_color="off",
    )
    if uf_maior_taxa is not None:
        k2.metric(
            "Maior Taxa Estadual",
            f"{uf_maior_taxa['sigla_uf']} ({uf_maior_taxa['taxa_anual_total']:.1f}/1k)",
            delta=f"Região {uf_maior_taxa['regiao']}",
            delta_color="off",
        )
    if uf_maior_cv is not None:
        amp_txt = f" | ΔT {uf_maior_cv['amplitude_termica_c']:.1f}°C" if pd.notna(uf_maior_cv["amplitude_termica_c"]) else ""
        k3.metric(
            "Maior Volatilidade Sazonal",
            f"{uf_maior_cv['sigla_uf']} (CV {uf_maior_cv['cv_sazonal_anti_pct']:.1f}%)",
            delta=f"Pico em {uf_maior_cv['mes_pico_anti']}{amp_txt}",
            delta_color="off",
        )
    if achado_top:
        k4.metric(
            "Correlação Mais Forte (|r|)",
            f"r = {achado_top['r']:+.2f}",
            delta=f"{achado_top['auxiliar'].split('[')[0].strip()} × {achado_top['metrica']}",
            delta_color="off",
        )

    col_m1, col_m2 = st.columns([3, 2])

    with col_m1:
        st.markdown("#### Matriz de Correlação de Pearson ($r$) entre Bases Auxiliares e Dispensação (UFs)")
        fig_heat = px.imshow(
            mat_corr,
            text_auto=".2f",
            color_continuous_scale="RdBu_r",
            zmin=-1,
            zmax=1,
            aspect="auto",
            labels={"color": "Pearson r"},
        )
        fig_heat.update_layout(height=420, margin=dict(l=10, r=10, t=20, b=10))
        st.plotly_chart(fig_heat, use_container_width=True)

    with col_m2:
        st.markdown("#### Principais Correlações Identificadas")
        st.caption(
            f"Calculadas transversalmente sobre as **{len(df_indicadores_uf)} UFs** selecionadas "
            "(valores próximos de +1 ou −1 indicam forte associação linear)."
        )
        for item in top_achados:
            sinal = "📈" if item["r"] > 0 else "📉"
            st.info(
                f"{sinal} **r = {item['r']:+.2f}** (correlação {item['forca']} {item['sentido']})  \n"
                f"**Base auxiliar:** {item['auxiliar']}  \n"
                f"**Dispensação:** {item['metrica']}"
            )

    st.markdown("---")
    st.markdown("#### Evolução Temporal Comparada por Região (Índice Sazonal Base 100 vs Taxa/1.000 hab)")

    modo_visao_tempo = st.radio(
        "Escala temporal:",
        options=["Índice Sazonal (Base 100 = média anual)", metrica_opcao],
        horizontal=True,
        key="tab1_escala",
    )

    # Agrega por Região x Mês
    df_reg_mes = (
        df_serie_uf.groupby(["regiao", "id_periodo", "mes", "mes_abrev"], as_index=False)
        .agg(
            dispensacoes=("dispensacoes", "sum"),
            embalagens=("embalagens", "sum"),
            populacao_uf=("populacao_uf", "sum"),
            temp_media_c=("temp_media_c", "mean"),
            precipitacao_media_mm=("precipitacao_media_mm", "mean"),
        )
        .sort_values(["regiao", "mes"])
    )
    df_reg_mes["disp_por_1000_hab"] = df_reg_mes["dispensacoes"] / df_reg_mes["populacao_uf"] * 1000.0
    df_reg_mes["emb_por_1000_hab"] = df_reg_mes["embalagens"] / df_reg_mes["populacao_uf"] * 1000.0
    media_reg = df_reg_mes.groupby("regiao")[metrica_col].transform("mean")
    df_reg_mes["indice_sazonal"] = df_reg_mes[metrica_col] / media_reg * 100.0

    y_col_t1 = "indice_sazonal" if "Base 100" in modo_visao_tempo else metrica_col
    fig_reg = px.line(
        df_reg_mes,
        x="mes_abrev",
        y=y_col_t1,
        color="regiao",
        markers=True,
        color_discrete_map=REGIAO_CORES,
        labels={
            "mes_abrev": f"Mês ({ANO_RECORTE})",
            y_col_t1: modo_visao_tempo,
            "regiao": "Região",
        },
        title=f"Variação Mensal da Dispensação ({classe_sel}) por Região",
    )
    if "Base 100" in modo_visao_tempo:
        fig_reg.add_hline(y=100, line_dash="dot", line_color="gray", annotation_text="Média Anual (100)")
    fig_reg.update_layout(height=380, xaxis_type="category")
    st.plotly_chart(fig_reg, use_container_width=True)

    # Tabela consolidada das UFs
    with st.expander("📋 Ver Tabela Consolidada de Indicadores por UF (todas as bases auxiliares)"):
        st.dataframe(
            df_indicadores_uf[[
                "sigla_uf", "regiao", "populacao_uf", "taxa_anual_total",
                "taxa_anual_anti", "taxa_anual_ctrl", "cv_sazonal_anti_pct",
                "temp_media_anual_c", "amplitude_termica_c", "precipitacao_total_mm",
                "pct_idosos_60_mais", "pct_criancas_0_14", "pct_cid_respiratorio",
                "r_temp_anti", "r_chuva_anti", "fator_climatico_dominante",
            ]].sort_values("taxa_anual_total", ascending=False),
            use_container_width=True,
            hide_index=True,
            column_config={
                "sigla_uf": "UF",
                "regiao": "Região",
                "populacao_uf": st.column_config.NumberColumn("População", format="%d"),
                "taxa_anual_total": st.column_config.NumberColumn("Total / 1k", format="%.1f"),
                "taxa_anual_anti": st.column_config.NumberColumn("Antimicrob. / 1k", format="%.1f"),
                "taxa_anual_ctrl": st.column_config.NumberColumn("Controlados / 1k", format="%.1f"),
                "cv_sazonal_anti_pct": st.column_config.NumberColumn("CV Sazonal %", format="%.1f%%"),
                "temp_media_anual_c": st.column_config.NumberColumn("Temp. Média (°C)", format="%.1f"),
                "amplitude_termica_c": st.column_config.NumberColumn("Amp. Térmica (°C)", format="%.1f"),
                "precipitacao_total_mm": st.column_config.NumberColumn("Chuva Anual (mm)", format="%.0f"),
                "pct_idosos_60_mais": st.column_config.NumberColumn("% Idosos 60+", format="%.1f%%"),
                "pct_criancas_0_14": st.column_config.NumberColumn("% Crianças 0–14", format="%.1f%%"),
                "pct_cid_respiratorio": st.column_config.NumberColumn("% CID Resp. (J)", format="%.1f%%"),
                "r_temp_anti": st.column_config.NumberColumn("r(Temp, Anti)", format="%+.2f"),
                "r_chuva_anti": st.column_config.NumberColumn("r(Chuva, Anti)", format="%+.2f"),
                "fator_climatico_dominante": "Vetor Climático Dominante",
            },
        )

# =============================================================================
# ABA 2: CLIMA (INMET) × TEMPO & ESTADOS
# =============================================================================
with tab2:
    st.subheader("Dinâmica Climática (INMET) × Variação Temporal da Dispensação nos Estados")
    st.write(
        "Compara **temperatura média (°C)** e **precipitação mensal (mm)** contra a taxa de dispensação "
        "ao longo dos 12 meses. Enquanto estados do **Sul e Sudeste** apresentam forte resposta inversa "
        "ao frio (picos de antimicrobianos no inverno), estados do **Norte e Nordeste** exibem maior "
        "sensibilidade ao regime de **chuvas** — contrastando ainda com os **controlados**, de menor sazonalidade climática."
    )

    c_ctrl1, c_ctrl2 = st.columns(2)
    var_clima = c_ctrl1.radio(
        "Variável climática INMET:",
        options=["Temperatura Média (°C)", "Precipitação Média (mm)"],
        horizontal=True,
    )
    clima_col = "temp_media_c" if "Temperatura" in var_clima else "precipitacao_media_mm"
    clima_cor = "#D62828" if "Temperatura" in var_clima else "#0077B6"

    classe_clima = c_ctrl2.radio(
        "Classe para série climática:",
        options=["Antimicrobianos", "Controlados"],
        horizontal=True,
    )

    df_clima_serie = preparar_serie_estadual_mensal(
        df_uf_mes_reg, classe=classe_clima, metrica_col=metrica_col
    )
    if uf_foco != "TODAS":
        df_plot_clima = df_clima_serie[df_clima_serie["sigla_uf"] == uf_foco].copy()
        titulo_escopo = f"UF: {uf_foco}"
    else:
        df_plot_clima = (
            df_clima_serie.groupby(["id_periodo", "mes", "mes_abrev"], as_index=False)
            .agg(
                dispensacoes=("dispensacoes", "sum"),
                embalagens=("embalagens", "sum"),
                populacao_uf=("populacao_uf", "sum"),
                temp_media_c=("temp_media_c", "mean"),
                precipitacao_media_mm=("precipitacao_media_mm", "mean"),
            )
            .sort_values("mes")
        )
        df_plot_clima["disp_por_1000_hab"] = df_plot_clima["dispensacoes"] / df_plot_clima["populacao_uf"] * 1000.0
        df_plot_clima["emb_por_1000_hab"] = df_plot_clima["embalagens"] / df_plot_clima["populacao_uf"] * 1000.0
        titulo_escopo = "Média das Regiões Selecionadas"

    col_c1, col_c2 = st.columns([2, 1])

    with col_c1:
        fig_dual = go.Figure()
        fig_dual.add_trace(go.Bar(
            x=df_plot_clima["mes_abrev"],
            y=df_plot_clima[metrica_col],
            name=f"{classe_clima} ({metrica_opcao})",
            marker_color="rgba(69, 123, 157, 0.78)",
            yaxis="y",
        ))
        fig_dual.add_trace(go.Scatter(
            x=df_plot_clima["mes_abrev"],
            y=df_plot_clima[clima_col],
            name=var_clima,
            mode="lines+markers",
            line=dict(color=clima_cor, width=3),
            yaxis="y2",
        ))
        fig_dual.update_layout(
            title=f"Evolução Mensal ({titulo_escopo}): {classe_clima} vs. {var_clima}",
            xaxis=dict(title=f"Mês ({ANO_RECORTE})", type="category"),
            yaxis=dict(title=metrica_opcao, side="left"),
            yaxis2=dict(title=var_clima, overlaying="y", side="right"),
            height=390,
            legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        )
        st.plotly_chart(fig_dual, use_container_width=True)

    with col_c2:
        r_local = calcular_pearson(df_plot_clima[clima_col], df_plot_clima[metrica_col])
        forca_l, sentido_l = classificar_correlacao(r_local)
        fig_sc_clima = scatter_com_tendencia(
            df_plot_clima,
            x=clima_col,
            y=metrica_col,
            text="mes_abrev",
            title=f"Dispersão Mensal ({titulo_escopo})",
            labels={clima_col: var_clima, metrica_col: metrica_opcao},
        )
        fig_sc_clima.update_traces(textposition="top center")
        fig_sc_clima.update_layout(height=310, margin=dict(t=40, b=10))
        st.plotly_chart(fig_sc_clima, use_container_width=True)
        st.metric(
            label=f"Pearson r ({len(df_plot_clima)} meses)",
            value="—" if pd.isna(r_local) else f"{r_local:+.2f}",
            delta=f"Correlação {forca_l} {sentido_l}",
            delta_color="off",
        )

    st.markdown("---")
    st.markdown("#### Correlação Climática em Todos os Estados: Temperatura vs. Precipitação (Antimicrobianos)")

    df_corr_uf = calcular_correlacoes_climaticas_por_uf(df_uf_mes_reg, metrica_col=metrica_col)
    col_r1, col_r2 = st.columns(2)

    with col_r1:
        fig_r_temp = px.bar(
            df_corr_uf.sort_values("r_temp_anti"),
            x="r_temp_anti",
            y="sigla_uf",
            orientation="h",
            color="regiao",
            color_discrete_map=REGIAO_CORES,
            title="Correlação Mensal: Temperatura × Antimicrobianos (por UF)",
            labels={"r_temp_anti": "Pearson r (negativo = mais venda no frio)", "sigla_uf": "UF", "regiao": "Região"},
        )
        fig_r_temp.add_vline(x=0, line_color="black", line_width=1)
        fig_r_temp.update_layout(height=500, xaxis_range=[-1, 1])
        st.plotly_chart(fig_r_temp, use_container_width=True)

    with col_r2:
        fig_r_chuva = px.bar(
            df_corr_uf.sort_values("r_chuva_anti", ascending=False),
            x="r_chuva_anti",
            y="sigla_uf",
            orientation="h",
            color="regiao",
            color_discrete_map=REGIAO_CORES,
            title="Correlação Mensal: Precipitação × Antimicrobianos (por UF)",
            labels={"r_chuva_anti": "Pearson r (positivo = mais venda na chuva)", "sigla_uf": "UF", "regiao": "Região"},
        )
        fig_r_chuva.add_vline(x=0, line_color="black", line_width=1)
        fig_r_chuva.update_layout(height=500, xaxis_range=[-1, 1])
        st.plotly_chart(fig_r_chuva, use_container_width=True)

    col_amp1, col_amp2 = st.columns([3, 2])

    with col_amp1:
        # Heatmap UF x Mês (Índice Sazonal Base 100)
        df_anti_saz = preparar_serie_estadual_mensal(
            df_uf_mes_reg, classe="Antimicrobianos", metrica_col=metrica_col
        )
        piv_saz = df_anti_saz.pivot_table(
            index="sigla_uf", columns="mes", values="indice_sazonal", aggfunc="mean"
        )
        # Ordena UFs pela amplitude térmica (mais frias/sazonais no topo)
        ordem_ufs = df_corr_uf.sort_values("amplitude_termica_c", ascending=False)["sigla_uf"].tolist()
        piv_saz = piv_saz.reindex([u for u in ordem_ufs if u in piv_saz.index])
        piv_saz.columns = [f"{m:02d}" for m in piv_saz.columns]

        fig_hm_saz = px.imshow(
            piv_saz,
            color_continuous_scale="YlGnBu",
            aspect="auto",
            title="Mapa de Calor Sazonal (Base 100): Antimicrobianos por UF × Mês (ordenado por Amplitude Térmica)",
            labels={"x": "Mês", "y": "UF", "color": "Índice (100=média)"},
        )
        fig_hm_saz.update_layout(height=480)
        st.plotly_chart(fig_hm_saz, use_container_width=True)

    with col_amp2:
        r_amp_cv = calcular_pearson(df_corr_uf["amplitude_termica_c"], df_corr_uf["cv_sazonal_anti_pct"])
        fig_amp = scatter_com_tendencia(
            df_corr_uf,
            x="amplitude_termica_c",
            y="cv_sazonal_anti_pct",
            color="regiao",
            size="populacao_uf",
            text="sigla_uf",
            color_discrete_map=REGIAO_CORES,
            title=f"Amplitude Térmica × Volatilidade Sazonal (r = {fmt_r(r_amp_cv)})",
            labels={
                "amplitude_termica_c": "Amplitude Térmica Anual (°C)",
                "cv_sazonal_anti_pct": "Coeficiente de Variação Mensal (%)",
                "regiao": "Região",
            },
        )
        fig_amp.update_traces(textposition="top center")
        fig_amp.update_layout(height=480)
        st.plotly_chart(fig_amp, use_container_width=True)

# =============================================================================
# ABA 3: ESTRUTURA ETÁRIA (IBGE CENSO 2022) × CONSUMO
# =============================================================================
with tab3:
    st.subheader("Demografia Etária (IBGE Censo 2022) × Padrões Estaduais e Temporais")
    st.write(
        "Cruza a pirâmide etária oficial do **IBGE (tabela 9514)** com a idade dos pacientes nas "
        "dispensações de antimicrobianos (`idade_paciente`, convertendo meses em `0-14 anos`) e correlaciona "
        "o **envelhecimento populacional estadual (% 60+)** com o consumo per capita de controlados e antimicrobianos."
    )

    col_e1, col_e2 = st.columns(2)

    with col_e1:
        r_id_ctrl = calcular_pearson(df_indicadores_uf["pct_idosos_60_mais"], df_indicadores_uf["taxa_anual_ctrl"])
        fig_id_ctrl = scatter_com_tendencia(
            df_indicadores_uf,
            x="pct_idosos_60_mais",
            y="taxa_anual_ctrl",
            color="regiao",
            size="populacao_uf",
            text="sigla_uf",
            color_discrete_map=REGIAO_CORES,
            title=f"Envelhecimento (% 60+) × Controlados / 1.000 hab (r = {fmt_r(r_id_ctrl)})",
            labels={
                "pct_idosos_60_mais": "% População com 60+ anos (IBGE)",
                "taxa_anual_ctrl": "Controlados / 1.000 hab (anual)",
                "regiao": "Região",
            },
        )
        fig_id_ctrl.update_traces(textposition="top center")
        fig_id_ctrl.update_layout(height=390)
        st.plotly_chart(fig_id_ctrl, use_container_width=True)

    with col_e2:
        r_id_anti = calcular_pearson(df_indicadores_uf["pct_idosos_60_mais"], df_indicadores_uf["taxa_anual_anti"])
        fig_id_anti = scatter_com_tendencia(
            df_indicadores_uf,
            x="pct_idosos_60_mais",
            y="taxa_anual_anti",
            color="regiao",
            size="populacao_uf",
            text="sigla_uf",
            color_discrete_map=REGIAO_CORES,
            title=f"Envelhecimento (% 60+) × Antimicrobianos / 1.000 hab (r = {fmt_r(r_id_anti)})",
            labels={
                "pct_idosos_60_mais": "% População com 60+ anos (IBGE)",
                "taxa_anual_anti": "Antimicrobianos / 1.000 hab (anual)",
                "regiao": "Região",
            },
        )
        fig_id_anti.update_traces(textposition="top center")
        fig_id_anti.update_layout(height=390)
        st.plotly_chart(fig_id_anti, use_container_width=True)

    st.markdown("---")
    df_int_etaria = calcular_intensidade_etaria(df_pop_etaria_reg, df_disp_etaria_reg)

    col_e3, col_e4 = st.columns([3, 2])

    with col_e3:
        # Índice de sobrerrepresentação por Região x Faixa Etária
        df_int_reg = (
            df_int_etaria.groupby(["regiao", "macro_faixa"], as_index=False)
            .agg(populacao_faixa=("populacao_faixa", "sum"), dispensacoes=("dispensacoes", "sum"))
        )
        tot_p_r = df_int_reg.groupby("regiao")["populacao_faixa"].transform("sum")
        tot_d_r = df_int_reg.groupby("regiao")["dispensacoes"].transform("sum")
        df_int_reg["indice"] = (df_int_reg["dispensacoes"] / tot_d_r) / (df_int_reg["populacao_faixa"] / tot_p_r)
        df_int_reg["macro_faixa"] = pd.Categorical(df_int_reg["macro_faixa"], categories=ORDEM_FAIXAS, ordered=True)
        df_int_reg = df_int_reg.sort_values(["macro_faixa", "regiao"])

        fig_sobre = px.bar(
            df_int_reg,
            x="macro_faixa",
            y="indice",
            color="regiao",
            barmode="group",
            color_discrete_map=REGIAO_CORES,
            title="Índice de Sobrerrepresentação Etária (% Dispensações ÷ % População IBGE)",
            labels={
                "macro_faixa": "Faixa Etária (Censo 2022)",
                "indice": "Índice (>1,0 = consumo acima da fatia populacional)",
                "regiao": "Região",
            },
        )
        fig_sobre.add_hline(y=1.0, line_dash="dash", line_color="black", annotation_text="Proporcionalidade (1,0)")
        fig_sobre.update_layout(height=390)
        st.plotly_chart(fig_sobre, use_container_width=True)

    with col_e4:
        # Evolução mensal por faixa etária (normalizada por 1.000 hab da própria faixa)
        df_disp_et_foco = df_disp_etaria_reg if uf_foco == "TODAS" else df_disp_etaria_reg[df_disp_etaria_reg["sigla_uf"] == uf_foco]
        df_pop_et_foco = df_pop_etaria_reg if uf_foco == "TODAS" else df_pop_etaria_reg[df_pop_etaria_reg["sigla_uf"] == uf_foco]

        pop_f = df_pop_et_foco.groupby("macro_faixa", as_index=False)["populacao_faixa"].sum()
        et_mes = (
            df_disp_et_foco.groupby(["mes", "mes_abrev", "macro_faixa"], as_index=False)["dispensacoes"]
            .sum()
            .merge(pop_f, on="macro_faixa", how="left")
            .sort_values(["macro_faixa", "mes"])
        )
        et_mes["taxa_faixa_1k"] = et_mes["dispensacoes"] / et_mes["populacao_faixa"] * 1000.0
        et_mes["macro_faixa"] = pd.Categorical(et_mes["macro_faixa"], categories=ORDEM_FAIXAS, ordered=True)

        fig_et_mes = px.line(
            et_mes.sort_values(["macro_faixa", "mes"]),
            x="mes_abrev",
            y="taxa_faixa_1k",
            color="macro_faixa",
            markers=True,
            title=f"Sazonalidade Mensal por Faixa Etária ({'Regiões' if uf_foco == 'TODAS' else uf_foco})",
            labels={
                "mes_abrev": f"Mês ({ANO_RECORTE})",
                "taxa_faixa_1k": "Dispensações / 1.000 hab da faixa",
                "macro_faixa": "Faixa Etária",
            },
        )
        fig_et_mes.update_layout(height=390, xaxis_type="category")
        st.plotly_chart(fig_et_mes, use_container_width=True)

# =============================================================================
# ABA 4: ESCALA POPULACIONAL & TERRITORIAL (IBGE POPULAÇÃO)
# =============================================================================
with tab4:
    st.subheader("Escala Urbana (IBGE População) × Concentração Municipal e Estadual")
    st.write(
        "Avalia se a dispensação per capita varia conforme o **porte populacional do município** "
        "e elimina o viés de volume absoluto das metrópoles para revelar polos regionais de alta demanda."
    )

    df_mun_foco = df_mun_reg.copy()
    if uf_foco != "TODAS":
        df_mun_foco = df_mun_foco[df_mun_foco["sigla_uf"] == uf_foco]

    df_mun_com_pop = df_mun_foco.dropna(subset=["populacao", "dispensacoes_por_1000_hab"]).copy()
    df_mun_com_pop = df_mun_com_pop[df_mun_com_pop["populacao"] > 0]
    df_mun_com_pop["porte"] = classificar_porte_municipal(df_mun_com_pop["populacao"])

    col_p1, col_p2 = st.columns([2, 3])

    with col_p1:
        porte_agg = (
            df_mun_com_pop.groupby("porte", observed=True, as_index=False)
            .agg(
                municipios=("nome_municipio", "count"),
                taxa_mediana=("dispensacoes_por_1000_hab", "median"),
                taxa_media=("dispensacoes_por_1000_hab", "mean"),
            )
        )
        fig_porte = px.bar(
            porte_agg,
            x="porte",
            y="taxa_mediana",
            text="taxa_mediana",
            color="taxa_mediana",
            color_continuous_scale="Tealgrn",
            title="Mediana de Dispensações / 1.000 hab por Porte Municipal",
            labels={"porte": "Porte Populacional (IBGE)", "taxa_mediana": "Mediana (Disp. / 1.000 hab)"},
        )
        fig_porte.update_traces(texttemplate="%{text:.0f}", textposition="outside")
        fig_porte.update_layout(height=360, coloraxis_showscale=False)
        st.plotly_chart(fig_porte, use_container_width=True)

    with col_p2:
        # Comparativo estadual: População IBGE vs Dispensações per Capita
        r_pop_taxa = calcular_pearson(df_indicadores_uf["populacao_uf"], df_indicadores_uf["taxa_anual_total"])
        fig_uf_pop = scatter_com_tendencia(
            df_indicadores_uf,
            x="populacao_uf",
            y="taxa_anual_total",
            color="regiao",
            text="sigla_uf",
            color_discrete_map=REGIAO_CORES,
            title=f"População Estadual (IBGE) × Taxa Anual / 1.000 hab (r = {fmt_r(r_pop_taxa)})",
            labels={
                "populacao_uf": "População do Estado (IBGE)",
                "taxa_anual_total": f"{metrica_opcao} (anual)",
                "regiao": "Região",
            },
        )
        fig_uf_pop.update_traces(textposition="top center")
        fig_uf_pop.update_layout(height=360)
        st.plotly_chart(fig_uf_pop, use_container_width=True)

    st.caption(
        f"Ranking per capita municipal abaixo considera municípios com mais de "
        f"**{POP_MIN_PER_CAPITA // 1000} mil habitantes** (população IBGE {ANO_RECORTE})."
    )
    col_t1, col_t2 = st.columns(2)

    with col_t1:
        top_abs = df_mun_foco.sort_values("dispensacoes", ascending=False).head(10)
        fig_abs = px.bar(
            top_abs,
            x="dispensacoes",
            y="nome_municipio",
            orientation="h",
            color="regiao",
            color_discrete_map=REGIAO_CORES,
            hover_data=["sigla_uf", "populacao"],
            title="Top 10 Municípios — Volume Absoluto de Dispensações",
            labels={"dispensacoes": "Dispensações", "nome_municipio": "Município", "regiao": "Região"},
        )
        fig_abs.update_layout(yaxis={"autorange": "reversed"}, height=350)
        st.plotly_chart(fig_abs, use_container_width=True)

    with col_t2:
        base_pc = df_mun_com_pop[df_mun_com_pop["populacao"] > POP_MIN_PER_CAPITA]
        top_pc = base_pc.sort_values("dispensacoes_por_1000_hab", ascending=False).head(10)
        fig_pc = px.bar(
            top_pc,
            x="dispensacoes_por_1000_hab",
            y="nome_municipio",
            orientation="h",
            color="dispensacoes_por_1000_hab",
            color_continuous_scale="Viridis",
            hover_data=["sigla_uf", "populacao"],
            title="Top 10 Municípios — Taxa per Capita (Dispensações / 1.000 hab)",
            labels={"dispensacoes_por_1000_hab": "Dispensações / 1.000 hab", "nome_municipio": "Município"},
        )
        fig_pc.update_layout(yaxis={"autorange": "reversed"}, height=350, coloraxis_showscale=False)
        st.plotly_chart(fig_pc, use_container_width=True)

# =============================================================================
# ABA 5: DIAGNÓSTICOS CLÍNICOS (DATASUS CID-10) × TEMPO, CLIMA E ESTADOS
# =============================================================================
with tab5:
    st.subheader("Diagnósticos Clínicos (CID-10 / DATASUS) × Variação Temporal e Regional")

    tot_anti_cov = df_cid_cov_reg["total_antimicrobianos"].sum()
    tot_com_cid = df_cid_cov_reg["com_cid10"].sum()
    pct_cov = (tot_com_cid / tot_anti_cov * 100.0) if tot_anti_cov > 0 else 0.0

    st.info(
        f"ℹ️ **Transparência estatística:** Na base pública do SNGPC ({ANO_RECORTE}), o preenchimento "
        f"do código CID-10 é opcional e aparece em **{pct_cov:.2f}%** das dispensações de antimicrobianos "
        f"({fmt_int(tot_com_cid)} registros). A análise abaixo explora essa amostra clínica para verificar "
        "se os diagnósticos respiratórios (`Capítulo J`) acompanham os picos sazonais de inverno e clima."
    )

    df_cap_foco = df_cid_cap_reg if uf_foco == "TODAS" else df_cid_cap_reg[df_cid_cap_reg["sigla_uf"] == uf_foco]
    df_top_foco = df_cid_top_reg if uf_foco == "TODAS" else df_cid_top_reg[df_cid_top_reg["sigla_uf"] == uf_foco]

    col_d1, col_d2 = st.columns([3, 2])

    with col_d1:
        cap_mes = (
            df_cap_foco.groupby(["mes", "mes_abrev", "capitulo_cid"], as_index=False)["dispensacoes"]
            .sum()
            .sort_values("mes")
        )
        fig_cap_mes = px.area(
            cap_mes,
            x="mes_abrev",
            y="dispensacoes",
            color="capitulo_cid",
            title=f"Evolução Mensal por Capítulo CID-10 ({'Regiões Selecionadas' if uf_foco == 'TODAS' else uf_foco})",
            labels={"mes_abrev": f"Mês ({ANO_RECORTE})", "dispensacoes": "Dispensações com CID-10", "capitulo_cid": "Capítulo"},
        )
        fig_cap_mes.update_layout(height=390, xaxis_type="category")
        st.plotly_chart(fig_cap_mes, use_container_width=True)

    with col_d2:
        r_temp_cidj = calcular_pearson(
            df_indicadores_uf["temp_media_anual_c"],
            df_indicadores_uf["pct_cid_respiratorio"],
        )
        fig_cid_clima = scatter_com_tendencia(
            df_indicadores_uf,
            x="temp_media_anual_c",
            y="pct_cid_respiratorio",
            color="regiao",
            text="sigla_uf",
            color_discrete_map=REGIAO_CORES,
            title=f"Temp. Média Estadual × % CID Respiratório J (r = {fmt_r(r_temp_cidj)})",
            labels={
                "temp_media_anual_c": "Temperatura Média Anual (°C)",
                "pct_cid_respiratorio": "% de Registros no Capítulo J (Respiratório)",
                "regiao": "Região",
            },
        )
        fig_cid_clima.update_traces(textposition="top center")
        fig_cid_clima.update_layout(height=390)
        st.plotly_chart(fig_cid_clima, use_container_width=True)

    st.markdown("---")
    col_d3, col_d4 = st.columns([3, 2])

    top10_cid = (
        df_top_foco.groupby(["cid_codigo", "cid_descricao"], as_index=False)
        .agg(dispensacoes=("dispensacoes", "sum"), embalagens=("embalagens", "sum"))
        .sort_values("dispensacoes", ascending=False)
        .head(10)
    )

    with col_d3:
        fig_cid_top = px.bar(
            top10_cid,
            x="dispensacoes",
            y="cid_descricao",
            orientation="h",
            color="dispensacoes",
            color_continuous_scale="Teal",
            hover_data=["cid_codigo", "embalagens"],
            title="Top 10 Condições Diagnósticas (CID-10) em Antimicrobianos",
            labels={"dispensacoes": "Dispensações", "cid_descricao": "Diagnóstico (CID-10)"},
        )
        fig_cid_top.update_layout(yaxis={"autorange": "reversed"}, height=380, coloraxis_showscale=False)
        st.plotly_chart(fig_cid_top, use_container_width=True)

    with col_d4:
        st.markdown("**Detalhamento dos Principais Códigos CID-10**")
        st.dataframe(
            top10_cid,
            use_container_width=True,
            hide_index=True,
            height=345,
            column_config={
                "cid_codigo": "CID-10",
                "cid_descricao": "Descrição",
                "dispensacoes": st.column_config.NumberColumn("Dispensações", format="%d"),
                "embalagens": st.column_config.NumberColumn("Embalagens", format="%d"),
            },
        )

st.markdown("---")
st.caption(
    "FarmaData — Projeto Integrado SBD2 / Universidade de Brasília (UnB). "
    "Bases integradas: SNGPC/Anvisa (Star Schema), IBGE (População 6579 e Faixa Etária Censo 2022), "
    "INMET (Estações Meteorológicas — Temperatura e Precipitação) e DATASUS (CID-10)."
)
