const http = require('http');
const { spawn } = require('child_process');
const server = http.createServer((req, res) => {
  req.resume();
  if (req.method === 'GET') {
    res.writeHead(200, {'Content-Type':'application/json'});
    res.end(JSON.stringify({data:[{id:'synthetic-model',object:'model',owned_by:'local'}]}));
    return;
  }
  res.writeHead(200, {'Content-Type':'text/event-stream'});
  const item = {id:'msg_synthetic',type:'message',status:'completed',role:'assistant',content:[{type:'output_text',text:'SYNTHETIC_CODEX_RESPONSE',annotations:[]}]};
  const response = {id:'resp_synthetic',object:'response',created_at:1,status:'completed',model:'synthetic-model',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}};
  const events = [
    {type:'response.created',response:{...response,status:'in_progress',output:[]}},
    {type:'response.output_item.added',output_index:0,item:{...item,status:'in_progress',content:[]}},
    {type:'response.content_part.added',item_id:item.id,output_index:0,content_index:0,part:{type:'output_text',text:'',annotations:[]}},
    {type:'response.output_text.delta',item_id:item.id,output_index:0,content_index:0,delta:'SYNTHETIC_CODEX_RESPONSE'},
    {type:'response.output_text.done',item_id:item.id,output_index:0,content_index:0,text:'SYNTHETIC_CODEX_RESPONSE'},
    {type:'response.content_part.done',item_id:item.id,output_index:0,content_index:0,part:item.content[0]},
    {type:'response.output_item.done',output_index:0,item},
    {type:'response.completed',response},
  ];
  res.end(events.map(event => 'event: '+event.type+'\ndata: '+JSON.stringify(event)+'\n\n').join(''));

});
server.listen(1234, '127.0.0.1', () => {
  const child = spawn('/opt/codex-spike/node_modules/.bin/codex', ['exec','--oss','--local-provider','lmstudio','--model','synthetic-model','--sandbox','workspace-write','--skip-git-repo-check','--ignore-user-config','--ephemeral','-'], {stdio:['pipe','inherit','inherit']});
  process.stdin.pipe(child.stdin);
  child.on('exit', code => {server.close(); process.exitCode=code ?? 1;});
  child.on('error', err => {console.error(err.message);server.close();process.exitCode=1;});
});
