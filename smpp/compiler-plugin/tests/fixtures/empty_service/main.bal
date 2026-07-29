// The code-action anchor: an empty service implements nothing, so nothing would ever
// be dispatched. (This is also where the editor offers the five handler templates.)
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y"});

service on lis {
}
