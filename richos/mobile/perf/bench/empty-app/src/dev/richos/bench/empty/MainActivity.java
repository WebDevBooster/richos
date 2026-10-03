package dev.richos.bench.empty;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** An app that does nothing: one Activity, one TextView. Its cold start is the phone's app-start floor. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setText("empty");
        setContentView(view);
    }
}
