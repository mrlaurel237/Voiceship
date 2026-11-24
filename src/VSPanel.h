// VSPanel.h — bouton flottant 🎙 et panneau de réglages.
#ifndef VS_PANEL_H
#define VS_PANEL_H
#ifdef __cplusplus
extern "C" {
#endif
void vs_panel_show(void);      // crée la fenêtre flottante (une fois)
void vs_panel_refresh(void);   // relit les réglages partagés
#ifdef __cplusplus
}
#endif
#endif
