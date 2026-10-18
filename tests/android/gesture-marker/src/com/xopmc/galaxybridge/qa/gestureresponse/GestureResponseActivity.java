package com.xopmc.galaxybridge.qa.gestureresponse;
import android.app.Activity;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.*;
import android.widget.OverScroller;
import android.graphics.*;
import android.util.Log;
public final class GestureResponseActivity extends Activity {
 public void onCreate(Bundle state) {
  super.onCreate(state); getWindow().setFlags(1024,1024);
  getWindow().getDecorView().setSystemUiVisibility(4096|1024|512|4|2);
  long nonce=getIntent().getLongExtra("gb_marker_nonce",0);
  if(nonce<0 || nonce>0xffffffffL)throw new IllegalArgumentException("marker nonce");
  setContentView(new Surface(this,nonce,getIntent().getBooleanExtra("gb_pressure_markers",false)));
  getWindow().setDecorFitsSystemWindows(false);
  getWindow().getInsetsController().hide(WindowInsets.Type.systemBars());
 }
 static final class Surface extends View {
  final Paint paint=new Paint(3),markerPaint=new Paint(); final OverScroller fling;
  final long markerNonce;
  final boolean pressureMarkers;
  int pressureCounter;
  final float density; VelocityTracker velocity;
  float offset,lastY,touchX,touchY; long sequence,draws,moves; boolean down;
  Surface(Activity activity,long nonce,boolean pressureMode) { super(activity); markerNonce=nonce; pressureMarkers=pressureMode; density=getResources().getDisplayMetrics().density;
   fling=new OverScroller(activity); paint.setTypeface(Typeface.create("sans-serif-medium",0)); setFocusable(true); }
  float rowHeight(){return 92*density;}
  int limit(){return Math.max(0,(int)(80*rowHeight()-getHeight()+130*density));}
  public boolean onTouchEvent(MotionEvent event) {
   int action=event.getActionMasked();
   if(pressureMarkers && (action==MotionEvent.ACTION_DOWN || action==MotionEvent.ACTION_MOVE)) {
    int counter=InputMarkerBits.pressureCounter(event.getPressure());
    pressureCounter=counter<0?65535:counter;
    android.os.Trace.beginSection("GBM1/input/"+pressureCounter+"/event_ms/"+event.getEventTime()); android.os.Trace.endSection();
    Log.i("GBGestureResponseQA","marker_input="+pressureCounter+" action="+action+" event_ms="+event.getEventTime()+" dispatch_ms="+SystemClock.uptimeMillis());
   }
   if(action==MotionEvent.ACTION_DOWN) {
    sequence++; moves=0;
    if(markerNonce!=0) {
     android.os.Trace.beginSection("GBM1/down/"+sequence+"/event_ms/"+event.getEventTime());
     android.os.Trace.endSection();
    }
     down=true; fling.abortAnimation(); lastY=event.getY();
    if(velocity!=null)velocity.recycle(); velocity=VelocityTracker.obtain();
    Log.i("GBGestureResponseQA","gesture="+sequence+" down_event_ms="+event.getEventTime()+" dispatch_ms="+SystemClock.uptimeMillis());
   }
   if(velocity!=null)velocity.addMovement(event);
   touchX=event.getX(); touchY=event.getY();
   if(action==MotionEvent.ACTION_MOVE) {
    moves++; offset=Math.max(0,Math.min(limit(),offset+lastY-touchY)); lastY=touchY;
   }
   if(action==MotionEvent.ACTION_UP || action==MotionEvent.ACTION_CANCEL) {
    down=false;
    if(action==MotionEvent.ACTION_UP && velocity!=null) {
     velocity.computeCurrentVelocity(1000); int speed=(int)-velocity.getYVelocity();
     if(Math.abs(speed)>80*density)fling.fling(0,(int)offset,0,speed,0,0,0,limit());
    }
    if(velocity!=null){velocity.recycle();velocity=null;}
    Log.i("GBGestureResponseQA","gesture="+sequence+" end_event_ms="+event.getEventTime()+" moves="+moves+" offset_px="+(int)offset);
   }
   invalidate(); return true;
  }
  public void computeScroll(){if(fling.computeScrollOffset()){offset=fling.getCurrY();postInvalidateOnAnimation();}}
  protected void onDraw(Canvas canvas) {
   if(markerNonce!=0)android.os.Trace.beginSection("GBM1/draw/"+(pressureMarkers?pressureCounter:sequence));
   try {
   draws++; canvas.drawColor(0xfff0f3fa);
   float header=130*density; canvas.save(); canvas.clipRect(0,header,getWidth(),getHeight());
   for(int i=0;i<80;i++) {
    float top=header+i*rowHeight()-offset;
    if(top+rowHeight()<header || top>getHeight())continue;
    paint.setColor(Color.WHITE);canvas.drawRoundRect(18*density,top+5*density,getWidth()-18*density,top+rowHeight()-5*density,22*density,22*density,paint);
    paint.setColor(new int[]{0xff376bfa,0xff8873ed,0xff1d9b86,0xffdf8a32}[i%4]);
    canvas.drawRoundRect(34*density,top+23*density,80*density,top+69*density,13*density,13*density,paint);
    paint.setColor(0xff202637);paint.setTextSize(20*density);canvas.drawText("Sample "+(i+1),100*density,top+43*density,paint);
    paint.setColor(0xff6b7285);paint.setTextSize(13*density);canvas.drawText("Neutral local gesture check",100*density,top+65*density,paint);
   }
   canvas.restore();paint.setColor((sequence&1)==0?0xff17488f:0xff6753c8);canvas.drawRect(0,0,getWidth(),header,paint);
   paint.setColor(Color.WHITE);paint.setTextSize(24*density);canvas.drawText("Gesture "+sequence,24*density,48*density,paint);
   paint.setTextSize(14*density);canvas.drawText("Offset "+(int)offset+"  Moves "+moves+"  Frames "+draws,24*density,78*density,paint);
   canvas.drawText("Swipe, scroll, tap — no permissions",24*density,104*density,paint);
   if(down){paint.setColor(0xb0f46450);canvas.drawCircle(touchX,touchY,18*density,paint);}
   if(markerNonce!=0 && sequence<=65535) {
    byte[] bits=InputMarkerBits.encode(markerNonce,pressureMarkers?pressureCounter:(int)sequence);
    float dx=getWidth()/23f,dy=getHeight()/23f;
    for(int bit=0;bit<96;bit++) {
     int row=bit/16,column=bit%16;
     boolean set=(bits[bit/8]&(1<<(7-bit%8)))!=0;
     markerPaint.setColor(set?Color.WHITE:Color.BLACK);
     canvas.drawRect((column+3.5f)*dx,(row+16.5f)*dy,(column+4.5f)*dx,(row+17.5f)*dy,markerPaint);
    }
   }
   } finally {if(markerNonce!=0)android.os.Trace.endSection();}
  }
 }
}
