package br.com.ricardomadureira.detector;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;

import org.json.JSONObject;

/**
 * Detector de ímã (a mesma lógica do app do iPhone).
 * Roda como serviço: continua funcionando com a tela bloqueada.
 * Estados enviados à tela: 0 desligado, 1 aprendendo, 2 pronto, 3 ímã perto, 4 dormindo, 5 acordando.
 */
public class Sensor extends Service implements SensorEventListener {

    public interface Ouvinte { void sinal(double valor, double limite, int estado); }

    static volatile Ouvinte ouvinte;
    static volatile Sensor ativo;
    static volatile boolean ligado = false;

    private static final String CANAL = "detector";
    private static final int PARADO = 0, APRENDENDO = 1, PRONTO = 2, DORMINDO = 4, ACORDANDO = 5;

    private SensorManager sm;
    private HandlerThread linha;
    private Handler h;
    private Vibrator vib;
    private PowerManager.WakeLock trava;

    // ajustes
    private double sens = 60, adapt = 70, forca = 100, dormirMin = 5;
    private boolean dupla = true, saidaLonga = false, dormir = true;

    // estado (só na linha do sensor)
    private int modo = PARADO;
    private double t0 = 0;
    private final double[] soma = new double[3];
    private int nSoma = 0;
    private final double[] base = new double[3];
    private final double[] suave = new double[3];
    private boolean temSuave = false;
    private double giro = 0, giroS = 0, valor = 0, limAtual = 10;
    private boolean perto = false;
    private int acima = 0;
    private double congeladoDesde = 0, silencioAte = 0, ultimaAtividade = 0, ultimoEnvio = 0;
    private int contAcordar = 0;
    private double limpoDesde = 0;
    private double pico = 0;
    private boolean recuperando = false;
    private double recDesde = 0, refT = 0;
    private final double[] refRec = new double[3];
    private int calmos = 0;
    private double ocupadoAte = 0;

    // ---------- comandos vindos da tela ----------

    static void comando(Context c, JSONObject o) {
        String cmd = o.optString("cmd");
        Sensor s = ativo;
        if ("ligar".equals(cmd)) {
            ligado = true;
            Intent i = new Intent(c, Sensor.class).putExtra("ajustes", o.toString());
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
        } else if ("desligar".equals(cmd)) {
            ligado = false;
            if (s != null) s.desligar();
        } else if ("ajustes".equals(cmd)) {
            if (s != null) s.h.post(() -> s.lerAjustes(o));
        }
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        ativo = this;
        sm = (SensorManager) getSystemService(SENSOR_SERVICE);
        if (Build.VERSION.SDK_INT >= 31) {
            vib = ((VibratorManager) getSystemService(VIBRATOR_MANAGER_SERVICE)).getDefaultVibrator();
        } else {
            vib = (Vibrator) getSystemService(VIBRATOR_SERVICE);
        }
        linha = new HandlerThread("sensor");
        linha.start();
        h = new Handler(linha.getLooper());
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        trava = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "detector:sensor");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        mostrarAviso();
        if (!trava.isHeld()) trava.acquire();
        String aj = intent != null ? intent.getStringExtra("ajustes") : null;
        h.post(() -> {
            try { if (aj != null) lerAjustes(new JSONObject(aj)); } catch (Exception ignored) {}
            iniciarSensores();
            comecarAprender();
        });
        return START_NOT_STICKY;
    }

    private void mostrarAviso() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CANAL, "Detector", NotificationManager.IMPORTANCE_MIN);
            ch.setShowBadge(false);
            ch.setSound(null, null);
            ch.enableVibration(false);
            nm.createNotificationChannel(ch);
        }
        PendingIntent abrir = PendingIntent.getActivity(this, 0, new Intent(this, Principal.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, CANAL) : new Notification.Builder(this);
        b.setSmallIcon(android.R.drawable.ic_lock_idle_lock)
                .setContentTitle("Detector")
                .setContentText("Ligado")
                .setContentIntent(abrir)
                .setOngoing(true);
        Notification n = b.build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(1, n);
        }
    }

    private void lerAjustes(JSONObject o) {
        sens = o.optDouble("sens", sens);
        adapt = o.optDouble("adapt", adapt);
        forca = o.optDouble("forca", forca);
        dormirMin = o.optDouble("dormirMin", dormirMin);
        dupla = o.optBoolean("dupla", dupla);
        saidaLonga = o.optBoolean("saidaLonga", saidaLonga);
        dormir = o.optBoolean("dormir", dormir);
    }

    private void iniciarSensores() {
        sm.unregisterListener(this);
        android.hardware.Sensor mag = null;
        if (Build.VERSION.SDK_INT >= 18) mag = sm.getDefaultSensor(android.hardware.Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED);
        if (mag == null) mag = sm.getDefaultSensor(android.hardware.Sensor.TYPE_MAGNETIC_FIELD);
        android.hardware.Sensor gir = sm.getDefaultSensor(android.hardware.Sensor.TYPE_GYROSCOPE);
        if (mag != null) sm.registerListener(this, mag, 10000, h);       // 100 vezes por segundo
        if (gir != null) sm.registerListener(this, gir, 20000, h);
        if (mag == null) enviarJa(0, 10, -1);                             // aparelho sem sensor magnético
    }

    private void desligar() {
        h.post(() -> {
            sm.unregisterListener(this);
            modo = PARADO;
            cortarVibracao();
            enviarJa(0, limite(), 0);
        });
        if (trava.isHeld()) trava.release();
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE); else stopForeground(true);
        stopSelf();
    }

    @Override
    public void onDestroy() {
        sm.unregisterListener(this);
        if (trava.isHeld()) trava.release();
        linha.quitSafely();
        ativo = null;
        super.onDestroy();
    }

    // ---------- leitura ----------

    @Override public void onAccuracyChanged(android.hardware.Sensor s, int a) {}

    @Override
    public void onSensorChanged(SensorEvent e) {
        int tipo = e.sensor.getType();
        if (tipo == android.hardware.Sensor.TYPE_GYROSCOPE) {
            giro = Math.sqrt(e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2]);
            return;
        }
        processar(e.values[0], e.values[1], e.values[2], agora());
    }

    private static double agora() { return SystemClock.elapsedRealtimeNanos() / 1e9; }

    private double limite() { return 80 * Math.pow(0.04, sens / 100); }

    private void comecarAprender() {
        modo = APRENDENDO;
        t0 = 0;
        soma[0] = soma[1] = soma[2] = 0; nSoma = 0;
        perto = false; acima = 0;
        enviarJa(0, limite(), 1);
    }

    private void processar(double x, double y, double z, double t) {
        if (modo == PARADO) return;
        if (!temSuave) { suave[0] = x; suave[1] = y; suave[2] = z; temSuave = true; }
        else { suave[0] += (x - suave[0]) * 0.35; suave[1] += (y - suave[1]) * 0.35; suave[2] += (z - suave[2]) * 0.35; }
        giroS += (giro - giroS) * 0.1;
        double dx = suave[0] - base[0], dy = suave[1] - base[1], dz = suave[2] - base[2];
        valor = Math.sqrt(dx * dx + dy * dy + dz * dz);
        limAtual = limite();

        // enquanto o próprio celular vibra (e logo depois), o sensor não conta: o motor de vibração tem ímã
        if (t < silencioAte && (modo == PRONTO || modo == DORMINDO || modo == ACORDANDO)) {
            contAcordar = 0;
            if (modo == PRONTO && perto) pico = Math.max(pico, valor);
            enviar(t);
            return;
        }

        switch (modo) {
            case APRENDENDO: aprender(t); break;
            case PRONTO: detectar(t, dx, dy, dz); break;
            case DORMINDO: dormindo(dx, dy, dz, t); break;
            case ACORDANDO: acordando(t); break;
        }
        enviar(t);
    }

    private void aprender(double t) {
        if (t0 == 0) t0 = t;
        if (t - t0 > 0.3) { soma[0] += suave[0]; soma[1] += suave[1]; soma[2] += suave[2]; nSoma++; }
        if (t - t0 >= 2.0 && nSoma > 20) {
            base[0] = soma[0] / nSoma; base[1] = soma[1] / nSoma; base[2] = soma[2] / nSoma;
            modo = PRONTO;
            perto = false; acima = 0; congeladoDesde = 0; recuperando = false;
            silencioAte = Math.max(silencioAte, t + 0.3);
            ultimaAtividade = t;
            tocar(3, 0.37, 0.28);                                  // pronto: vum vum vum
        }
    }

    private void moverBase(double dx, double dy, double dz, double a) { base[0] += dx * a; base[1] += dy * a; base[2] += dz * a; }
    private void baseIgualSuave() { base[0] = suave[0]; base[1] = suave[1]; base[2] = suave[2]; }

    private void detectar(double t, double dx, double dy, double dz) {
        double a = adapt / 100;
        double k = 0.3 + 6 * (1 - a);                              // quanto o movimento "esconde" o sinal
        double limEf = limite() * (1 + k * giroS);
        limAtual = limEf;
        if (giroS > 1.0 + 2.0 * a) {                               // girando muito: não vibra
            if (!perto) moverBase(dx, dy, dz, 0.08);
            silencioAte = Math.max(silencioAte, t + 0.35);
            acima = 0;
            return;
        }
        // depois da saída: espera o "restinho" do ímã se acalmar e aceita como o novo normal
        if (recuperando) {
            if (t - refT >= 0.25) {
                double ax = suave[0] - refRec[0], ay = suave[1] - refRec[1], az = suave[2] - refRec[2];
                calmos = Math.sqrt(ax * ax + ay * ay + az * az) < limEf * 0.3 ? calmos + 1 : 0;
                refRec[0] = suave[0]; refRec[1] = suave[1]; refRec[2] = suave[2]; refT = t;
            }
            if (calmos >= 2 || t - recDesde > 5) {
                baseIgualSuave(); recuperando = false; acima = 0; congeladoDesde = 0;
            }
            return;
        }
        if (valor < limEf * 0.5) {
            moverBase(dx, dy, dz, 0.004 + (0.02 + 0.1 * (1 - a)) * Math.min(giroS, 2));
            congeladoDesde = 0;
        } else {
            if (congeladoDesde == 0) congeladoDesde = t;
            if (t - congeladoDesde > (perto ? 15 : 5)) {         // mudado muito tempo: é a sala, não o ímã
                baseIgualSuave(); congeladoDesde = 0; perto = false; acima = 0;
            }
        }
        if (t >= silencioAte) {
            if (!perto) {
                acima = valor > limEf ? acima + 1 : 0;
                if (acima >= 2) {
                    perto = true;
                    pico = valor;
                    ultimaAtividade = t;
                    tocar(3, 0.37, 0.28);                          // chegou: vum vum vum
                }
            } else {
                pico = Math.max(pico, valor);
            }
            if (perto && valor < Math.max(limEf * 0.6, pico * 0.35)) {   // saída: o sinal caiu bem
                perto = false;
                acima = 0;
                ultimaAtividade = t;
                recuperando = true; recDesde = t; calmos = 0; refT = t;
                refRec[0] = suave[0]; refRec[1] = suave[1]; refRec[2] = suave[2];
                if (dupla) {
                    if (saidaLonga) tocar(1, 1.0, 0); else tocar(3, 0.37, 0.28);   // saiu
                }
            }
        }
        if (dormir && !perto && t - ultimaAtividade > dormirMin * 60) {
            modo = DORMINDO;
            contAcordar = 0;
        }
    }

    private double forteAcordar() { return Math.max(60, limite() * 4); }

    private void dormindo(double dx, double dy, double dz, double t) {
        if (giroS > 0.3) { baseIgualSuave(); contAcordar = 0; return; }
        if (valor > forteAcordar()) {
            contAcordar++;
            if (contAcordar >= 80) {
                modo = ACORDANDO;
                t0 = t;
                limpoDesde = 0;
                tocar(1, 0.4, 0);                                   // acordei: um vum
            }
        } else {
            contAcordar = Math.max(0, contAcordar - 2);
            if (valor < forteAcordar() * 0.3) moverBase(dx, dy, dz, 0.01);
        }
    }

    private void acordando(double t) {
        if (valor < forteAcordar() * 0.25 && giroS < 0.5) {
            if (limpoDesde == 0) limpoDesde = t;
            if (t - limpoDesde > 0.6) { comecarAprender(); return; }
        } else {
            limpoDesde = 0;
        }
        if (t - t0 > 8) comecarAprender();
    }

    private void enviar(double t) {
        if (t - ultimoEnvio < 0.05) return;
        ultimoEnvio = t;
        int estado;
        switch (modo) {
            case APRENDENDO: estado = 1; break;
            case PRONTO: estado = perto ? 3 : 2; break;
            case DORMINDO: estado = 4; break;
            case ACORDANDO: estado = 5; break;
            default: estado = 0;
        }
        double v = (modo == PRONTO || modo == DORMINDO) ? valor : 0;
        enviarJa(v, limAtual, estado);
    }

    private void enviarJa(double v, double lim, int estado) {
        Ouvinte o = ouvinte;
        if (o != null) o.sinal(v, lim, estado);
    }

    // ---------- vibração ----------

    /** Um aviso de cada vez: se já está vibrando, não acumula outro. */
    private void tocar(int pulsos, double dur, double gap) {
        double t = agora();
        double total = pulsos * dur + (pulsos - 1) * gap;
        silencioAte = Math.max(silencioAte, t + total + 0.6);       // fica "surdo" enquanto vibra
        if (t < ocupadoAte) return;
        ocupadoAte = t + total;
        if (vib == null || !vib.hasVibrator()) return;
        long[] tempos = new long[pulsos * 2];
        int[] forcas = new int[pulsos * 2];
        for (int i = 0; i < pulsos; i++) {
            tempos[i * 2] = i == 0 ? 0 : Math.round(gap * 1000);
            tempos[i * 2 + 1] = Math.round(dur * 1000);
            forcas[i * 2] = 0;
            forcas[i * 2 + 1] = Math.max(1, Math.min(255, (int) Math.round(1 + 254 * forca / 100)));
        }
        if (Build.VERSION.SDK_INT >= 26) {
            if (vib.hasAmplitudeControl()) vib.vibrate(VibrationEffect.createWaveform(tempos, forcas, -1));
            else vib.vibrate(VibrationEffect.createWaveform(tempos, -1));
        } else {
            vib.vibrate(tempos, -1);
        }
    }

    private void cortarVibracao() {
        ocupadoAte = 0;
        if (vib != null) vib.cancel();
    }
}
